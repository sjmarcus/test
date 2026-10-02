using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        // Pooled HttpClient: the worker is reused across invocations, and a
        // new HttpClient per call exhausts sockets under any real load.
        services.AddHttpClient("github");

        // One CosmosClient for the life of the worker; see RegistryStore.
        services.AddSingleton<SecretDistributor.RegistryStore>();
        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();
    })
    .Build();

host.Run();
