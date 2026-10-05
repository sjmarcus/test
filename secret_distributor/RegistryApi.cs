using System.Net;
using System.Text.Json;
using Azure;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Azure.Cosmos;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace SecretDistributor;

/// <summary>
/// HTTP API over the secret registry. The single writer of registry entries.
///
///   GET    /api/me                  who you are and what you may do
///   GET    /api/registry            list entries                  Reader
///   GET    /api/registry/{id}       one entry (ETag in the body)  Reader
///   PUT    /api/registry/{id}       create, or update with If-Match   Editor
///                                   (pushes the current value to any target not yet pushed)
///   DELETE /api/registry/{id}       remove                        Admin
///   GET    /api/state/{id}          what was last pushed          Reader
///
/// {id} is the Key Vault secret name. Bodies never carry secret values.
///
/// AUTH: every route is AuthorizationLevel.Anonymous at the Functions layer on
/// purpose. App Service Authentication (Easy Auth) sits in front of the app and
/// signs users in against Entra; these handlers then check the caller's app
/// role. See <see cref="Caller"/> for why this fails closed when Easy Auth is
/// not enabled — the routes must never be reachable without it.
/// </summary>
public class RegistryApi
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    private readonly RegistryStore _store;
    private readonly SecretPusher _pusher;
    private readonly ILogger<RegistryApi> _log;

    public RegistryApi(RegistryStore store, SecretPusher pusher, ILogger<RegistryApi> log)
    {
        _store = store;
        _pusher = pusher;
        _log = log;
    }

    [Function("Registry_Me")]
    public Task<HttpResponseData> Me(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "me")] HttpRequestData req) =>
        Guard(req, RegistryRole.None, requireStore: false, caller =>
            Reply(req, HttpStatusCode.OK, new
            {
                name = caller.Name,
                role = caller.Role.ToString(),
                canEdit = caller.CanEdit,
                canDelete = caller.CanDelete,
            }));

    [Function("Registry_List")]
    public Task<HttpResponseData> List(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "registry")] HttpRequestData req,
        CancellationToken ct) =>
        Guard(req, RegistryRole.Reader, requireStore: true, async _ =>
            await Reply(req, HttpStatusCode.OK, await _store.ListEntriesAsync(ct)));

    [Function("Registry_Get")]
    public Task<HttpResponseData> Get(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "registry/{id}")] HttpRequestData req,
        string id, CancellationToken ct) =>
        Guard(req, RegistryRole.Reader, requireStore: true, async _ =>
        {
            var entry = await _store.GetEntryAsync(id, ct);
            return entry is null
                ? await Problem(req, HttpStatusCode.NotFound, $"No registry entry '{id}'.")
                : await Reply(req, HttpStatusCode.OK, entry, entry.ETag);
        });

    [Function("Registry_Put")]
    public Task<HttpResponseData> Put(
        [HttpTrigger(AuthorizationLevel.Anonymous, "put", Route = "registry/{id}")] HttpRequestData req,
        string id, CancellationToken ct) =>
        Guard(req, RegistryRole.Editor, requireStore: true, async caller =>
        {
            RegistryEntry? entry;
            try
            {
                entry = await JsonSerializer.DeserializeAsync<RegistryEntry>(req.Body, Json, ct);
            }
            catch (JsonException ex)
            {
                return await Problem(req, HttpStatusCode.BadRequest, $"Body is not valid JSON: {ex.Message}");
            }

            if (entry is null)
                return await Problem(req, HttpStatusCode.BadRequest, "Body is required.");

            // The route is authoritative. A body id that disagrees is a client
            // bug worth surfacing rather than silently picking one.
            if (!string.IsNullOrEmpty(entry.Id) && !string.Equals(entry.Id, id, StringComparison.Ordinal))
                return await Problem(req, HttpStatusCode.BadRequest,
                    $"Body id '{entry.Id}' does not match route id '{id}'.");
            entry.Id = id;

            var errors = entry.Validate();
            if (errors.Count > 0)
                return await Problem(req, HttpStatusCode.BadRequest, "Invalid entry.", errors);

            var ifMatch = IfMatch(req);
            var saved = await _store.SaveEntryAsync(entry, ifMatch, caller.Name, ct);
            _log.LogInformation("Registry entry '{Id}' {Action} by {Caller} with {Count} target(s).",
                saved.Id, ifMatch is null ? "created" : "updated", caller.Name, saved.Targets.Count);

            // The entry is saved; pushing is best-effort on top of it. A secret
            // that will not rotate for months must not wait for a new version
            // to reach a newly added repository.
            var distribution = await PushNewTargetsAsync(saved, ct);

            var body = JsonSerializer.SerializeToNode(saved, Json)!.AsObject();
            body["distribution"] = JsonSerializer.SerializeToNode(distribution, Json);
            return await Reply(req, ifMatch is null ? HttpStatusCode.Created : HttpStatusCode.OK, body, saved.ETag);
        });

    [Function("Registry_Delete")]
    public Task<HttpResponseData> Delete(
        [HttpTrigger(AuthorizationLevel.Anonymous, "delete", Route = "registry/{id}")] HttpRequestData req,
        string id, CancellationToken ct) =>
        Guard(req, RegistryRole.Admin, requireStore: true, async caller =>
        {
            if (!await _store.DeleteEntryAsync(id, IfMatch(req), ct))
                return await Problem(req, HttpStatusCode.NotFound, $"No registry entry '{id}'.");

            _log.LogInformation("Registry entry '{Id}' deleted by {Caller}.", id, caller.Name);
            return req.CreateResponse(HttpStatusCode.NoContent);
        });

    [Function("Registry_State")]
    public Task<HttpResponseData> State(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "state/{id}")] HttpRequestData req,
        string id, CancellationToken ct) =>
        Guard(req, RegistryRole.Reader, requireStore: true, async _ =>
        {
            var state = await _store.GetStateAsync(id, ct);
            return state is null
                ? await Problem(req, HttpStatusCode.NotFound, $"Nothing has been distributed for '{id}' yet.")
                : await Reply(req, HttpStatusCode.OK, state, state.ETag);
        });

    // --- distribution on save ----------------------------------------------

    /// <summary>
    /// Pushes the secret's CURRENT value to targets that have never been pushed
    /// (no recorded state), so adding a repository takes effect now instead of
    /// at the next new version. Targets that already have state are left alone.
    /// Never throws: the entry is already saved, so a failure here is reported
    /// in the response rather than turned into an error for a write that
    /// succeeded. A failed target has no state, so saving again retries it, and
    /// the next new version pushes to every target regardless.
    /// </summary>
    private async Task<object> PushNewTargetsAsync(RegistryEntry saved, CancellationToken ct)
    {
        try
        {
            if (!saved.Enabled)
                return new { status = "skipped", message = "Entry is disabled; nothing was pushed." };

            var recorded = (await _store.GetStateAsync(saved.Id, ct))?.Targets.Select(t => t.Key).ToHashSet()
                           ?? new HashSet<string>();
            var pending = saved.Targets.Where(t => !recorded.Contains(t.Key)).ToList();
            if (pending.Count == 0)
                return new { status = "none", message = "No new targets to push." };

            var vaultUri = SecretPusher.VaultUri;
            if (string.IsNullOrWhiteSpace(vaultUri))
                return new { status = "skipped", message = "KEY_VAULT_URI is not set; nothing was pushed." };

            var vault = SecretPusher.OpenVault(vaultUri);
            KeyVaultSecret secret;
            try
            {
                secret = await vault.GetSecretAsync(saved.Id, cancellationToken: ct);
            }
            catch (RequestFailedException ex) when (ex.Status is 403 or 404)
            {
                _log.LogWarning(ex, "Registry entry '{Id}' saved but its Key Vault secret could not be read (HTTP {Status}).",
                    saved.Id, ex.Status);
                return new
                {
                    status = "skipped",
                    message = ex.Status == 404
                        ? "No Key Vault secret with this name exists yet. New targets will be pushed when its first version is created."
                        : "The app cannot read this Key Vault secret, so nothing was pushed.",
                };
            }

            var result = await _pusher.PushAsync(vault, secret, saved, pending, ct);
            return new
            {
                status = result.Targets.All(t => t.Status == "pushed") ? "pushed" : "partial",
                message = (string?)null,
                targets = result.Targets,
            };
        }
        catch (Exception ex) when (ex is RequestFailedException or CosmosException)
        {
            _log.LogError(ex, "Registry entry '{Id}' saved but pushing its new targets failed.", saved.Id);
            return new { status = "failed", message = "The entry was saved, but pushing to its new targets failed. Save again to retry." };
        }
    }

    // --- plumbing ----------------------------------------------------------

    /// <summary>
    /// Authenticates, authorises, then runs the handler. Maps store failures to
    /// status codes so each handler stays about its own logic.
    /// </summary>
    private async Task<HttpResponseData> Guard(
        HttpRequestData req, RegistryRole minimum, bool requireStore, Func<Caller, Task<HttpResponseData>> action)
    {
        if (!Caller.TryResolve(req, out var caller, out var status, out var message))
            return await Problem(req, status, message);

        if (caller!.Role < minimum)
        {
            _log.LogWarning("{Caller} (role {Role}) was refused {Method} {Path}; needs {Needed}.",
                caller.Name, caller.Role, req.Method, req.Url.AbsolutePath, minimum);
            return await Problem(req, HttpStatusCode.Forbidden, caller.Role == RegistryRole.None
                ? $"You are signed in as {caller.Name} but have no registry role. Ask an admin to assign one."
                : $"This needs the {minimum} role; you have {caller.Role}.");
        }

        if (requireStore && !_store.IsConfigured)
            return await Problem(req, HttpStatusCode.ServiceUnavailable,
                "Registry is not configured: COSMOS_ENDPOINT / COSMOS_DATABASE are not set.");

        try
        {
            return await action(caller);
        }
        catch (ConcurrencyException ex)
        {
            return await Problem(req, HttpStatusCode.PreconditionFailed, ex.Message);
        }
        catch (CosmosException ex)
        {
            // The detail can carry request context; log it, return only the status.
            _log.LogError(ex, "Cosmos call failed with HTTP {Status}.", (int)ex.StatusCode);
            return await Problem(req, HttpStatusCode.BadGateway, $"Registry store returned HTTP {(int)ex.StatusCode}.");
        }
    }

    private static string? IfMatch(HttpRequestData req) =>
        req.Headers.TryGetValues("If-Match", out var values)
            ? values.FirstOrDefault()?.Trim()
            : null;

    private static async Task<HttpResponseData> Reply(HttpRequestData req, HttpStatusCode status, object body, string? etag = null)
    {
        var res = req.CreateResponse(status);
        if (etag is not null) res.Headers.Add("ETag", etag);
        res.Headers.Add("Content-Type", "application/json; charset=utf-8");
        await res.WriteStringAsync(JsonSerializer.Serialize(body, Json));
        return res;
    }

    private static Task<HttpResponseData> Problem(HttpRequestData req, HttpStatusCode status, string message, IEnumerable<string>? errors = null) =>
        Reply(req, status, new { error = message, details = errors });
}
