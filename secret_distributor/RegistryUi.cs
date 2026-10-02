using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;

namespace SecretDistributor;

/// <summary>
/// Serves the registry's single-page UI at /api/ui.
///
/// The route is Anonymous at the Functions layer, but it is NOT public: App
/// Service Authentication (Easy Auth) sits in front of the whole app and sends
/// unauthenticated browsers to the Entra sign-in page before this runs. The
/// page then calls the API with the user's session, and the API checks their
/// role — see <see cref="RegistryApi"/>.
///
/// While REGISTRY_OPEN_ACCESS=true and Easy Auth is off (see <see cref="Caller"/>),
/// this page IS reachable by anyone who has the URL.
/// </summary>
public class RegistryUi
{
    private static readonly Lazy<string> Html = new(() =>
    {
        var asm = Assembly.GetExecutingAssembly();
        // Resource names are prefixed with the assembly namespace, so match by suffix.
        var name = asm.GetManifestResourceNames().Single(n => n.EndsWith("index.html", StringComparison.Ordinal));
        using var reader = new StreamReader(asm.GetManifestResourceStream(name)!);
        return reader.ReadToEnd();
    });

    [Function("Registry_Ui")]
    public HttpResponseData Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "ui")] HttpRequestData req)
    {
        // Per-request nonce so the CSP can forbid every script and style except
        // the two inline blocks in the page itself.
        var nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(16));

        var res = req.CreateResponse(HttpStatusCode.OK);
        res.Headers.Add("Content-Type", "text/html; charset=utf-8");
        res.Headers.Add("Content-Security-Policy",
            $"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; " +
            "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
        res.Headers.Add("X-Content-Type-Options", "nosniff");
        res.Headers.Add("Referrer-Policy", "no-referrer");
        res.Headers.Add("Cache-Control", "no-store");
        res.WriteString(Html.Value.Replace("{{nonce}}", nonce));
        return res;
    }
}
