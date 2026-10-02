using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker.Http;

namespace SecretDistributor;

/// <summary>Ordered so a higher role includes everything below it.</summary>
public enum RegistryRole
{
    None = 0,
    Reader = 1,
    Editor = 2,
    Admin = 3,
}

/// <summary>
/// Who is calling, as established by App Service Authentication (Easy Auth).
///
/// Easy Auth signs the user in against Entra and forwards the result to the
/// function in the X-MS-CLIENT-PRINCIPAL header. This class only READS that
/// header — it never authenticates anyone itself — so it is only safe when Easy
/// Auth is actually in front of the app. Easy Auth strips any client-supplied
/// copy of the header, but with Easy Auth off the platform would pass a forged
/// one straight through. <see cref="TryResolve"/> therefore fails CLOSED in
/// Azure when auth is not enabled, rather than trusting the header.
///
/// Roles come from Entra app roles on the app registration:
///     Registry.Reader   view entries and state
///     Registry.Editor   + create and update entries
///     Registry.Admin    + delete entries
/// A person with several roles gets the highest.
///
/// TEMPORARY open mode: with Easy Auth off and REGISTRY_OPEN_ACCESS=true,
/// every caller is an Admin and nobody is authenticated. For testing the
/// distribution logic until sign-in is set up; turn it off before real use.
/// </summary>
public sealed class Caller
{
    private static readonly string[] RoleClaimTypes =
    {
        "roles",
        "http://schemas.microsoft.com/ws/2008/06/identity/claims/role",
    };

    private static readonly string[] NameClaimTypes = { "preferred_username", "upn", "name" };

    public string Name { get; init; } = "";
    public RegistryRole Role { get; init; }

    public bool CanEdit => Role >= RegistryRole.Editor;
    public bool CanDelete => Role >= RegistryRole.Admin;

    /// <summary>
    /// True when hosted on App Service / Functions. Deliberately checks several
    /// platform variables rather than one: which of them is present varies by
    /// hosting plan (Linux Consumption vs Premium vs Windows), and getting this
    /// wrong in the permissive direction would let the local-dev role override
    /// apply in Azure. Any marker counts, so this errs towards "in Azure".
    /// WEBSITE_AUTH_ENABLED is included because Easy Auth being on proves it.
    /// </summary>
    private static bool RunningInAzure() =>
        new[] { "WEBSITE_SITE_NAME", "WEBSITE_HOSTNAME", "WEBSITE_INSTANCE_ID", "WEBSITE_AUTH_ENABLED", "CONTAINER_NAME" }
            .Any(v => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable(v)));

    /// <summary>
    /// Resolves the caller, or explains why not. Status is 401 when there is no
    /// signed-in user and 503 when the app is misconfigured (auth not enabled).
    /// </summary>
    public static bool TryResolve(HttpRequestData req, out Caller? caller, out HttpStatusCode status, out string message)
    {
        caller = null;
        status = HttpStatusCode.Unauthorized;
        message = "Sign in required.";

        var inAzure = RunningInAzure();

        if (!inAzure)
        {
            // Local development only: there is no Easy Auth in front of a local
            // host, so a role can be granted through an environment variable.
            // Deliberately ignored in Azure, so it cannot be used as a backdoor.
            var local = Environment.GetEnvironmentVariable("REGISTRY_LOCAL_ROLE");
            if (Enum.TryParse<RegistryRole>(local, ignoreCase: true, out var localRole) && localRole != RegistryRole.None)
            {
                caller = new Caller { Name = "local-dev", Role = localRole };
                return true;
            }
            message = "Not running in Azure and REGISTRY_LOCAL_ROLE is not set.";
            return false;
        }

        if (!string.Equals(Environment.GetEnvironmentVariable("WEBSITE_AUTH_ENABLED"), "True", StringComparison.OrdinalIgnoreCase))
        {
            // Explicit opt-in for testing before sign-in exists: everyone who
            // can reach the app is treated as an Admin. Needs REGISTRY_OPEN_ACCESS
            // to be exactly "true", so a missing or mistyped setting still fails
            // closed. Only reachable when Easy Auth is OFF; with it on, the real
            // identity is used and this setting has no effect.
            if (string.Equals(Environment.GetEnvironmentVariable("REGISTRY_OPEN_ACCESS"), "true", StringComparison.Ordinal))
            {
                caller = new Caller { Name = "anonymous (open access)", Role = RegistryRole.Admin };
                return true;
            }

            status = HttpStatusCode.ServiceUnavailable;
            message = "Authentication is not enabled on this app, so identity headers cannot be trusted. Refusing the request.";
            return false;
        }

        if (!req.Headers.TryGetValues("X-MS-CLIENT-PRINCIPAL", out var values))
            return false;

        try
        {
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(values.First()));
            using var doc = JsonDocument.Parse(json);

            var role = RegistryRole.None;
            string? name = null;

            if (doc.RootElement.TryGetProperty("claims", out var claims))
            {
                foreach (var claim in claims.EnumerateArray())
                {
                    var type = claim.GetProperty("typ").GetString() ?? "";
                    var val = claim.GetProperty("val").GetString() ?? "";

                    if (RoleClaimTypes.Contains(type, StringComparer.OrdinalIgnoreCase) && val.StartsWith("Registry.", StringComparison.Ordinal)
                        && Enum.TryParse<RegistryRole>(val["Registry.".Length..], out var parsed) && parsed > role)
                        role = parsed;

                    if (name is null && NameClaimTypes.Contains(type, StringComparer.OrdinalIgnoreCase))
                        name = val;
                }
            }

            if (req.Headers.TryGetValues("X-MS-CLIENT-PRINCIPAL-NAME", out var n) && !string.IsNullOrWhiteSpace(n.First()))
                name = n.First();

            caller = new Caller { Name = name ?? "unknown", Role = role };
            return true;
        }
        catch (Exception ex) when (ex is FormatException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            message = "The identity header could not be read.";
            return false;
        }
    }
}
