import 'dart:io';

/// External players must use a private tailnet address, never a public alias.
bool isTailscaleEndpoint(Uri endpoint) {
  if (!['http', 'https'].contains(endpoint.scheme) ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.host.isEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    return false;
  }
  final parsedHost = endpoint.host.toLowerCase();
  final host = parsedHost.startsWith('[') && parsedHost.endsWith(']')
      ? parsedHost.substring(1, parsedHost.length - 1)
      : parsedHost;
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    return host.endsWith('.ts.net');
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
  }
  return bytes[0] == 0xfd &&
      bytes[1] == 0x7a &&
      bytes[2] == 0x11 &&
      bytes[3] == 0x5c &&
      bytes[4] == 0xa1 &&
      bytes[5] == 0xe0;
}
