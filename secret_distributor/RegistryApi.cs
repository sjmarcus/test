using System.Net;
using System.Text.Json;
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
    private readonly ILogger<RegistryApi> _log;

    public RegistryApi(RegistryStore store, ILogger<RegistryApi> log)
    {
        _store = store;
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
            return await Reply(req, ifMatch is null ? HttpStatusCode.Created : HttpStatusCode.OK, saved, saved.ETag);
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
