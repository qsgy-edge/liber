# Test TLS certificates

Throwaway certificates for `test/source_tls_exception_test.dart`, which serves
them from an in-process `SecureSocket` (`SecureServerSocket`). The keys are
test-only and guard nothing.

| File | Role |
| --- | --- |
| `localhost.crt` / `localhost.key` | A self-signed leaf. No client trusts it, so it is the certificate failure ADR 0011 §5 is about: the server every exception test uses. |
| `testca.crt` / `testca.key` | The test certificate authority. The "a certificate the client trusts needs no exception" test installs it as its trust anchor. |
| `localhost-signed.crt` / `localhost-signed.key` | The server leaf `testca` signed. A client that trusts `testca.crt` accepts it, with no stored exception. |

## Why the signed leaf is shaped the way it is

macOS verifies a client connection through `Security.framework` rather than
BoringSSL: the SDK's `runtime/bin/security_context_macos.cc` hands the peer
chain and the certificates from `setTrustedCertificates` to
`SecTrustCreateWithCertificates` / `SecTrustSetAnchorCertificates` /
`SecTrustGetTrustResult`. That evaluator enforces
[Apple's TLS server certificate requirements](https://support.apple.com/en-us/103769)
for any certificate whose `NotBefore` is after 2019-07-01:

- an `ExtendedKeyUsage` extension containing `id-kp-serverAuth`;
- a validity period of 825 days or fewer;
- the server's name in the Subject Alternative Name extension (a DNS name in
  the CommonName is no longer trusted).

BoringSSL, which verifies on Linux and Windows, enforces none of these, so a
fixture that skips them is accepted there and rejected by macOS. That is what
happened to the first version of `localhost.crt`: a self-signed 100-year
certificate with no EKU, trusted as its own anchor, passed on Linux and Windows
and failed the macOS job of CI run 35214067286. The signed leaf therefore
carries `extendedKeyUsage=serverAuth`, 820 days of validity, and both the DNS
and the iPAddress form of `127.0.0.1` in its subject alternative name — the test
dials the IP literal, and the SDK's own test certificate carries both forms of
`127.0.0.1` as well.

## Generation

With OpenSSL 3.x, from this directory.

The self-signed leaf (unchanged since the fixture was introduced):

```sh
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout localhost.key -out localhost.crt -days 36500 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

The test certificate authority:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout testca.key -out testca.crt \
  -subj "/CN=Liber test certificate authority" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "extendedKeyUsage=serverAuth"
```

The leaf `testca` signs:

```sh
openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout localhost-signed.key -out localhost-signed.csr -subj "/CN=localhost"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1\n' \
  > localhost-signed.ext
openssl x509 -req -in localhost-signed.csr -CA testca.crt -CAkey testca.key \
  -CAcreateserial -sha256 -days 820 \
  -extfile localhost-signed.ext -out localhost-signed.crt
rm localhost-signed.csr localhost-signed.ext testca.srl
```

The signed leaf expires on 2028-12-15: Apple's 825-day cap is what keeps macOS
from rejecting it, so the pair has to be regenerated with these commands (and
the date in this sentence moved) before then.
