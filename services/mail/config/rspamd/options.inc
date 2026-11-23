# DNS through the mail stack's own resolver (unbound): blocklists refuse
# queries from shared public resolvers.
dns {
  nameserver = ["127.0.0.1"];
}
