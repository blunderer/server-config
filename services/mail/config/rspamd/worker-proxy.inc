# Milter for postfix (smtpd_milters): the proxy scans each message itself
# (self_scan) and answers with headers, or, once enabled, a rejection.
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
