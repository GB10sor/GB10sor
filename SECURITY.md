# Security policy

## Supported versions

Only the latest commit on `main` is supported. Preview branches are for review and testing and may change without notice.

## Reporting a vulnerability

Please report security issues privately. Do not open a public issue or discussion with exploit details, credentials, host information, private addresses, or logs.

Preferred channels:

1. Open a [private GitHub security advisory](https://github.com/GB10sor/GB10sor/security/advisories/new).
2. If the advisory form is unavailable, email [sp@gb10sor.ai](mailto:sp@gb10sor.ai) with the subject `[GB10sor security]`. Encrypt sensitive details with the project key below.

| Contact | Email | Primary GPG fingerprint |
| :--- | :--- | :--- |
| Sloptimist Prime | `sp@gb10sor.ai` | `33CB 9ED0 E2A8 B20F 8C5B FC83 A2F5 BAE3 4BC0 8A40` |

Include the affected commit or version, impact, reproduction steps, and the smallest useful set of sanitized logs. Please allow time to investigate and coordinate disclosure before publishing details.

## GPG identity

Security replies are signed with the project YubiKey. Verify the full primary-key fingerprint before trusting a signature or encrypting a report:

```text
33CB 9ED0 E2A8 B20F 8C5B  FC83 A2F5 BAE3 4BC0 8A40
```

Current subkeys:

```text
Signing:    1119 E470 1C44 3921 A08F  C3E9 4D21 CE19 EE3D B04D
Encryption: B3D1 DA93 9951 C521 E908  2A70 8455 BA5A AAC6 A41F
```

Import the [repository copy of the public key](security/GB10sor-security-key.asc), then verify the fingerprint:

```bash
gpg --import security/GB10sor-security-key.asc
gpg --fingerprint 33CB9ED0E2A8B20F8C5BFC83A2F5BAE34BC08A40
```

Encrypt a report before attaching it to email:

```bash
gpg --armor --output report.txt.asc --encrypt \
  --recipient 33CB9ED0E2A8B20F8C5BFC83A2F5BAE34BC08A40 report.txt
```

Do not select a key by email address alone. Compare the complete primary fingerprint above before use.

## Operational security

Deployment trust boundaries and fail-closed behavior are documented in the [operational security guide](docs/security.md).
