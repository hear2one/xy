# Optional client-side policy; independent of the VPS IP family.
CDN_DOWNLOAD_SOCKOPT_ENC=""
case "${CDN_DOWNLOAD_IPV4:-false}" in
  true)
    CDN_DOWNLOAD_SOCKOPT_ENC='%2C%22sockopt%22%3A%7B%22domainStrategy%22%3A%22ForceIPv4%22%7D'
    ;;
  false) ;;
  *) echo 'CDN_DOWNLOAD_IPV4 must be true or false' >&2; exit 1 ;;
esac
