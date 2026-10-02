using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Identity;
using Microsoft.Azure.Cosmos;

namespace SecretDistributor;

/// <summary>Thrown when an If-Match / create-only precondition fails.</summary>
public sealed class ConcurrencyException : Exception
{
    public ConcurrencyException(string message) : base(message) { }
}

/// <summary>
/// Cosmos-backed access to the secret registry and its state.
///
/// Auth is the managed identity via DefaultAzureCredential — the account has
/// local (key) auth disabled, so there is no connection string to configure.
/// Registered as a singleton: a CosmosClient is meant to be shared, and
/// creating one per invocation exhausts sockets.
///
/// Writes carry an ETag precondition. Two writers racing on one entry get a
/// <see cref="ConcurrencyException"/> rather than a silent lost update.
/// </summary>
public sealed class RegistryStore
{
    private const string RegistryContainer = "registry";
    private const string StateContainer = "state";

    private readonly Lazy<CosmosClient>? _client;
    private readonly string? _database;

    public RegistryStore()
    {
        var endpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
        _database = Environment.GetEnvironmentVariable("COSMOS_DATABASE");

        if (string.IsNullOrWhiteSpace(endpoint) || string.IsNullOrWhiteSpace(_database))
            return; // IsConfigured stays false; callers fall back or report 503.

        _client = new Lazy<CosmosClient>(() => new CosmosClient(
            endpoint,
            new DefaultAzureCredential(),
            new CosmosClientOptions
            {
                // Gateway keeps the socket count down on Consumption, and the
                // registry is far too small for Direct's latency win to matter.
                ConnectionMode = ConnectionMode.Gateway,
                UseSystemTextJsonSerializerWithOptions = new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
                },
            }));
    }

    public bool IsConfigured => _client is not null;

    private Container Registry => _client!.Value.GetContainer(_database, RegistryContainer);
    private Container State => _client!.Value.GetContainer(_database, StateContainer);

    // --- registry ----------------------------------------------------------

    public async Task<RegistryEntry?> GetEntryAsync(string id, CancellationToken ct)
    {
        try
        {
            return (await Registry.ReadItemAsync<RegistryEntry>(id, new PartitionKey(id), cancellationToken: ct)).Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    public async Task<List<RegistryEntry>> ListEntriesAsync(CancellationToken ct)
    {
        var results = new List<RegistryEntry>();
        using var feed = Registry.GetItemQueryIterator<RegistryEntry>("SELECT * FROM c ORDER BY c.id");
        while (feed.HasMoreResults)
            results.AddRange(await feed.ReadNextAsync(ct));
        return results;
    }

    /// <summary>
    /// Create when <paramref name="ifMatch"/> is null (fails if the id exists),
    /// otherwise replace only if the stored ETag still equals it.
    /// </summary>
    public async Task<RegistryEntry> SaveEntryAsync(RegistryEntry entry, string? ifMatch, string updatedBy, CancellationToken ct)
    {
        entry.UpdatedUtc = DateTime.UtcNow;
        entry.UpdatedBy = updatedBy;
        entry.ETag = null; // system property; the precondition below is what matters

        try
        {
            var response = ifMatch is null
                ? await Registry.CreateItemAsync(entry, new PartitionKey(entry.Id), cancellationToken: ct)
                : await Registry.ReplaceItemAsync(entry, entry.Id, new PartitionKey(entry.Id),
                    new ItemRequestOptions { IfMatchEtag = ifMatch }, ct);
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            throw new ConcurrencyException($"Entry '{entry.Id}' already exists; send If-Match to update it.");
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.PreconditionFailed)
        {
            throw new ConcurrencyException($"Entry '{entry.Id}' changed since it was read; re-fetch and retry.");
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound && ifMatch is not null)
        {
            throw new ConcurrencyException($"Entry '{entry.Id}' no longer exists.");
        }
    }

    /// <summary>Returns false when there was nothing to delete.</summary>
    public async Task<bool> DeleteEntryAsync(string id, string? ifMatch, CancellationToken ct)
    {
        try
        {
            await Registry.DeleteItemAsync<RegistryEntry>(id, new PartitionKey(id),
                ifMatch is null ? null : new ItemRequestOptions { IfMatchEtag = ifMatch }, ct);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return false;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.PreconditionFailed)
        {
            throw new ConcurrencyException($"Entry '{id}' changed since it was read; re-fetch and retry.");
        }

        // Bookkeeping for a secret that is no longer distributed is just noise.
        try
        {
            await State.DeleteItemAsync<SecretState>(id, new PartitionKey(id), cancellationToken: ct);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound) { }

        return true;
    }

    // --- state -------------------------------------------------------------

    public async Task<SecretState?> GetStateAsync(string id, CancellationToken ct)
    {
        try
        {
            return (await State.ReadItemAsync<SecretState>(id, new PartitionKey(id), cancellationToken: ct)).Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    /// <summary>
    /// Last-writer-wins upsert. Deliberate: state is a record of what was most
    /// recently pushed, so an overlapping run overwriting it with an equally
    /// recent result is correct, and a precondition would only turn a harmless
    /// race into a retry.
    /// </summary>
    public Task UpsertStateAsync(SecretState state, CancellationToken ct)
    {
        state.ETag = null;
        return State.UpsertItemAsync(state, new PartitionKey(state.Id), cancellationToken: ct);
    }
}
