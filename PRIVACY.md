# Privacy and data collection

The skill files in this repository do not independently collect telemetry. They provide
instructions that an agent follows in response to a user request. The microsoft-sql-admin plugin
also provides configuration for the separately downloaded SQL Tools MCP server; an agent host
may download and start that server when the plugin is enabled. Agent hosts, command-line tools,
MCP servers, and Microsoft cloud services have their own data collection settings and privacy
terms.

To prevent server downloads or startup, disable the plugin's sql-tools MCP entry in the host or
remove the administration plugin. To prevent workflow network requests, do not ask an agent to
call external services. Configure or disable telemetry for the agent host and external tools
using their product documentation.

## Microsoft data collection notice

Data Collection. The software may collect information about you and your use of the software and send it to
Microsoft. Microsoft may use this information to provide services and improve our products and
services. You may turn off the telemetry as described in the repository. There are also some
features in the software that may enable you and Microsoft to collect data from users of your
applications. If you use these features, you must comply with applicable law, including
providing appropriate notices to users of your applications together with a copy of Microsoft's
privacy statement. Our privacy statement is located at
https://go.microsoft.com/fwlink/?LinkID=824704. You can learn more about data collection and use
in the help documentation and our privacy statement. Your use of the software operates as your
consent to these practices.
