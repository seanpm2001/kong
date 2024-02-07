local typedefs = require "kong.db.schema.typedefs"

return {
  {
    ttl = true,
    primary_key = { "id" },
    name = "keyauth_credentials",
    endpoint_key = "key",
    cache_key = { "key" },
    workspaceable = true,
    admin_api_name = "key-auths",
    admin_api_nested_name = "key-auth",
    db_export = kong.configuration.lazy_loaded_consumers == "off", -- TODO: move this check to a helper
    fields = {
      { id = typedefs.uuid },
      { created_at = typedefs.auto_timestamp_s },
      { consumer = { type = "foreign", reference = "consumers", required = true, on_delete = "cascade", }, },
      { key = { type = "string", required = false, unique = true, auto = true }, },
      { tags = typedefs.tags },
    },
  },
}
