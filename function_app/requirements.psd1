# INTENTIONALLY EMPTY.
#
# Linux Consumption (Y1) on the Legion platform does NOT support Managed
# Dependencies. Any module listed here makes the PowerShell worker throw at
# function-load time:
#
#   "Failed to install function app dependencies. Error: 'Managed
#    Dependencies is not supported in Linux Consumption on Legion.'"
#
# That failure happens BEFORE any function code runs, so every function in
# the app fails to load and HTTP triggers return a bare 500 with no body.
#
# Instead, the Az modules are vendored into ./Modules and shipped inside the
# deployment package. The PowerShell worker auto-imports everything under
# Modules/ at startup, so no explicit Import-Module is needed for them.
#
# See: https://aka.ms/functions-powershell-include-modules
#
# If this app ever moves to Elastic Premium (EP1) or App Service, managed
# dependencies become available again and this can be reinstated -- see the
# sku_name note in ../terraform/main.tf.
@{
}
