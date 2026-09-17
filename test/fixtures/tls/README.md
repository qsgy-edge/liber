# Test TLS certificate

`localhost.crt` and `localhost.key` are a throwaway, self-signed certificate for
`localhost` and `127.0.0.1`, generated once with:

```
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout localhost.key -out localhost.crt -days 36500 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

`test/source_tls_exception_test.dart` serves it from an in-process
`SecureServerSocket`: an ordinary client rejects it as untrusted (the
certificate failure ADR 0011 §5 is about), and a client told to trust it accepts
it (the valid-certificate side of the same server). The key is test-only and
guards nothing.
