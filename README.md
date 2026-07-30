# ABAP Cloud SDK for Azure

An enterprise-grade SDK that lets **ABAP Cloud** (SAP BAIP ABAP Environment / S/4HANA Cloud) applications
call **Azure REST APIs** with the same ergonomics you expect from the official Azure SDKs for Java or .NET:
a layered HTTP **pipeline**, pluggable **credentials**, typed **exceptions**, and strongly-typed service
clients — all written in released, cloud-ready ABAP (`ABAP for Cloud Development`, language version 5).

> **Built for Steampunk.** This SDK is designed from the ground up to be **ABAP Cloud–compliant**: it
> targets **SAP BAIP ABAP Environment (a.k.a. "Steampunk") and S/4HANA Cloud Public Edition**, and uses only
> released, cloud-ready APIs. It is a fresh, cloud-native counterpart to the established
> [**microsoft/ABAP-SDK-for-Azure**](https://github.com/microsoft/ABAP-SDK-for-Azure) — the classic SDK for
> **classic / on-premises ABAP** (SAP NetWeaver, S/4HANA on-prem). The two are complementary: pick the
> classic SDK for classic ABAP stacks, and this one when you run on ABAP Cloud / Steampunk.

> **🌱 Initial release (v0.1 · public preview / MVP) — we want your feedback.**
> This is the **first public release** and an intentional starting point, not a finished product. It covers
> three Azure services end-to-end (Storage Blob, Compute, Resource Graph) on a shared runtime core, with
> **182 ABAP Unit tests**. We are publishing it **early and openly so the ABAP Cloud community can try it,
> use it in real scenarios, and tell us what works and what is missing.** That feedback will directly drive
> the roadmap — more services, more operations, and hardening — and the public API may still evolve before a
> stable 1.0. **Please share your experience, ideas, and issues** — see [Feedback](#feedback) and
> [Contributing](#contributing).

---

## Table of contents

- [Why this SDK](#why-this-sdk)
- [Architecture](#architecture)
- [Authentication](#authentication)
- [Implemented services](#implemented-services)
- [Testing](#testing)
- [Package layout](#package-layout)
- [Getting started](#getting-started)
- [Running the demos](#running-the-demos)
- [Design principles & conventions](#design-principles--conventions)
- [Contributing](#contributing)
- [Code of Conduct](#code-of-conduct)
- [Security](#security)
- [License](#license)
- [Trademarks](#trademarks)

---

## Why this SDK

Calling Azure from ABAP usually means hand-rolling `if_web_http_client` calls, string-building URLs,
and parsing JSON/XML inline in every program. This SDK factors all of that into a reusable runtime so a
caller just does:

```abap
DATA(lo_blob) = NEW zcl_az_blob_client(
                  iv_account_name = 'mystorageacct'
                  io_credential   = NEW zcl_az_client_secret_cred(
                                        iv_client_id     = '...'
                                        iv_client_secret = '...'
                                        iv_tenant_id     = '...' ) ).

DATA(lo_blobs) = lo_blob->list_blobs( iv_container = 'my-container' ).
```

The runtime transparently handles authentication (token acquisition + caching), retry with back-off,
logging, `Content-Length` edge cases, binary vs. textual payloads, and typed error propagation.

---

## Architecture

The SDK is organized as a **runtime core** that every service client transports through.

```
        Service client (zcl_az_blob_client / _compute_client / _resourcegraph_client)
                                   |
                                   v
     zcl_az_http_pipeline  ──►  ordered list of policies (zif_az_http_pipeline_policy)
        1. zcl_az_policy_retry        (transient-failure retry, immutable context)
        2. auth policy                (one of:)
             • zcl_az_policy_auth        — Entra ID bearer token
             • zcl_az_policy_sas         — Shared Access Signature (query string)
             • zcl_az_policy_shared_key  — Storage Shared Key (HMAC-SHA256 header)
        3. zcl_az_policy_logging      (request/response timing)
        4. zcl_az_pipeline_trans_policy → transport
                                   |
                                   v
        zcl_az_http_client  (if_web_http_client)  ──►  Azure REST endpoint
```

### Core building blocks

| Concern            | Type(s) | Notes |
|--------------------|---------|-------|
| HTTP pipeline      | `zcl_az_http_pipeline`, `zcl_az_pipeline_context` | Ordered policy chain; the context is **immutable** so retries re-run the chain correctly. |
| Pipeline policy    | `zif_az_http_pipeline_policy` | Single-method seam (`process`); every cross-cutting concern is a policy. |
| Transport          | `zif_az_http_client` → `zcl_az_http_client` | Wraps `if_web_http_client`; propagates response headers, classifies textual vs. binary bodies, and sends `Content-Length: 0` on body-less writes (avoids Azure HTTP 411). |
| Request / response | `zcl_az_http_request`, `zcl_az_http_response` | Plain DTOs; response exposes `get_header`, `is_textual_content_type`, binary body. |
| Credentials        | `zif_az_token_credential` (+ implementations) | See [Authentication](#authentication). |
| Access token       | `zcl_az_access_token`, `zcl_az_token_response` | Bearer token with expiry handling. |
| Crypto             | `zcl_az_crypto` | Shared `hmac_sha256_b64` used by Shared Key and User Delegation SAS signing. |
| Serialization      | `zcl_az_blob_xml_deserializer`, `zcl_az_rg_json_serializer` | XML (ixml) and JSON (`/ui2/cl_json`) helpers. |
| Exceptions         | `zcx_azure` (base) → `zcx_az_auth_error`, `zcx_az_http_error`, `zcx_az_service_error`, `zcx_az_serialization_error` | Typed hierarchy; clients raise these instead of returning codes. |

---

## Authentication

Auth is injected centrally by a pipeline policy, so service clients are **auth-agnostic**. The SDK ships
the full set of options used in production Azure integrations:

### Microsoft Entra ID token credentials — `zif_az_token_credential`

> Microsoft Entra ID is the identity service formerly known as Azure Active Directory (Azure AD).

| Credential | Use case |
|------------|----------|
| `zcl_az_client_secret_cred`   | Service principal (client id + secret + tenant). |
| `zcl_az_managed_identity_cred`| System- or user-assigned Managed Identity via the IMDS endpoint (no secret in code). |
| `zcl_az_environment_credential`| Reads configuration from the `zaz_config` table. |
| `zcl_az_default_credential` (+ `zcl_az_default_cred_builder`) | Chained credential that tries providers in order and reports which providers were skipped. |

### Storage data-plane auth — recommended order

For accessing blob **data**, the SDK supports four schemes.

| Preference | Scheme | Type | Traceable to an identity? | Account key required? |
|:---------:|--------|------|:-------------------------:|:---------------------:|
| **1 · Recommended** | **User Delegation SAS** — `zcl_az_blob_udk_sas` | Entra ID-signed SAS | **Yes** (skoid/sktid) | **No** |
| **2 · Preferred** | **Entra ID credential** — `zcl_az_policy_auth` + a `zif_az_token_credential` | Entra ID bearer token | **Yes** | **No** |
| 3 · Use with care | Shared Access Signature (SAS) — `zcl_az_policy_sas` | Pre-issued signed URL | No | No (but often minted from the account key) |
| 4 · Least recommended | Shared Key (account key) — `zcl_az_policy_shared_key` | Account-key HMAC | No | **Yes** |

**1 — User Delegation SAS (recommended).** The builder `zcl_az_blob_udk_sas` authenticates with Entra ID to
obtain a *user delegation key*, signs a short-lived, identity-traceable, revocable SAS (HMAC-SHA256, service
version 2020-12-06+), and returns a ready-to-use blob client — with **no account key anywhere in the
system**. Every request is attributable to the signing Entra ID identity and honours its RBAC permissions.
It follows the
[Create a user delegation SAS](https://learn.microsoft.com/en-us/rest/api/storageservices/create-user-delegation-sas)
specification.

**2 — Entra ID credential (preferred).** A direct Entra ID bearer token (service principal or Managed
Identity). Requires a *Storage Blob Data* RBAC role on the account, so access stays identity-based and
auditable.

**3 & 4 — SAS and Shared Key (use only when necessary).** A plain **Shared Access Signature** or a **Shared
Key** (account key) signature are supported for interoperability and for scenarios where an Entra ID
identity is not available. They are the **least recommended** options: neither is traceable to a user, an
account-key SAS/Shared Key grants broad, hard-to-revoke access, and the account key — if used — must be
handled as a high-value secret. Prefer User Delegation SAS or a direct Entra ID credential whenever
possible.

> **Constructor note.** When several inputs are supplied, `zcl_az_blob_client` selects the scheme by this
> resolution order: `iv_sas_token` → `iv_account_key` → `io_credential` (Entra ID). This is how a *pre-built*
> SAS is honoured first; to follow the recommended approach, build the client through
> `zcl_az_blob_udk_sas=>create_blob_client( )` (User Delegation SAS) or pass an `io_credential` — and simply
> do not pass `iv_sas_token` / `iv_account_key` unless you specifically need them.

---

## Implemented services

| Service | Interface | Client | Surface | Highlights |
|---------|-----------|--------|---------|------------|
| **Storage Blob** | `zif_az_blob_service` (73 methods) | `zcl_az_blob_client` | 4 ergonomic typed methods + the full generated REST surface | `list_containers`, `list_blobs`, `download_blob`, `upload_blob` (typed models + XML deserialization) plus containers/leases/blocks/pages/append/service operations. Binary-safe (images, arbitrary bytes). |
| **Compute** | `zif_az_compute_service` (189 methods) | `zcl_az_compute_client` | Full Virtual Machines / Scale Sets / Images / Hosts surface | Typed responses (`r_*` structures), path/query building, body serialization, action endpoints (`start`/`deallocate`/`restart`/…). |
| **Resource Graph** | `zif_az_resourcegraph_service` (3 methods) | `zcl_az_resourcegraph_client` | Query execution + operations | Ergonomic `query_resources` facade (primitives in, OO result out) **plus** the generated `resources( body )` (typed `query_request`/`query_response`, facets, options) and `operations_list`. |

Result models: `zcl_az_list_containers_result`, `zcl_az_list_blobs_result`, `zcl_az_blob_content`,
`zcl_az_upload_blob_result`, `zcl_az_rg_query_result`.

---

## Testing

The SDK ships with **182 ABAP Unit test methods** — all `RISK LEVEL HARMLESS DURATION SHORT` (no network),
plus self-skipping integration tests for optional live verification.

### How it is tested

- **Injection seam** — every client and credential constructor accepts an optional
  `io_http_client TYPE REF TO zif_az_http_client`. Production omits it (uses the real transport); tests
  inject a double.
- **Test doubles** — `zcl_az_http_client_mock` (stub + spy: scripts responses, captures every request)
  and `zcl_az_token_credential_fake` (auth-agnostic credential).
- **Dual-seam rule** — a client has *two* HTTP paths: its transport **and** the credential's own token
  acquisition. Offline tests mock **both** (e.g. a Managed Identity credential backed by an IMDS mock,
  injected into a blob client backed by a transport mock).
- **Pure functions** — signing (`zcl_az_crypto`, Shared Key, User Delegation SAS StringToSign) and
  transport edge-cases (`Content-Length:0`/411, header propagation) are extracted into pure, directly
  unit-testable methods, including an RFC 4231 HMAC-SHA256 known-answer vector.
- **Known-answer & shape coverage** — rather than testing all 189 generated compute methods, tests cover
  each distinct *operation shape* (typed GET, GET + optional query, PUT with body + conditional headers,
  DELETE + query, body-less POST action, list scopes, error/retry/transport).

### Test counts (per area)

| Area | Test methods |
|------|-------------:|
| Storage Blob client (`zcl_az_blob_client_test`) | 52 |
| Compute client (`zcl_az_compute_client_test`) | 31 |
| User Delegation SAS builder (`zcl_az_blob_udk_sas`) | 14 |
| Resource Graph client (`zcl_az_rg_client_test`) | 12 |
| Shared Key policy | 10 |
| HTTP transport helpers | 9 |
| Client-secret credential | 7 |
| HTTP response | 7 |
| SAS policy | 6 |
| Managed Identity credential | 6 |
| Default credential | 6 |
| Crypto (HMAC) | 5 |
| Retry policy | 5 |
| Auth policy / pipeline context / environment credential | 4 each |
| **Total** | **182** |

Integration tests (real Azure) are marked `RISK LEVEL DANGEROUS` and **self-skip** unless a real account
and secret/SAS are configured in `zcl_az_test_environment`, so the suite is green out of the box.

---

## Package layout

```
ZABAP_SDK_AZURE                     (root)
├── ZABAP_AZ_CORE                   HTTP pipeline, transport, crypto, serialization, exceptions, models
│   ├── ZABAP_AZ_CORE_HTTP          zcl_az_http_client / _request / _response
│   ├── ZABAP_AZ_CORE_PIPELINE      zcl_az_http_pipeline / _pipeline_context / _trans_policy
│   ├── ZABAP_AZ_CORE_POLICIES      zcl_az_policy_retry / _auth / _logging / _sas / _shared_key
│   ├── ZABAP_AZ_CORE_SERIALIZATION zcl_az_crypto, zcl_az_blob_xml_deserializer, zcl_az_rg_json_serializer
│   ├── ZABAP_AZ_CORE_MODELS        result / DTO classes
│   └── ZABAP_AZ_CORE_EXCEPTION     zcx_azure hierarchy
├── ZABAP_AZ_IDENTITY               credentials + token model
│   ├── ZABAP_AZ_IDENTITY_CREDENTIAL zcl_az_client_secret_cred / _managed_identity_cred / _environment_credential / _default_credential
│   └── ZABAP_AZ_IDENTITY_TOKEN     zcl_az_access_token / zcl_az_token_response
├── ZABAP_AZ_SERVICES
│   ├── ZABAP_AZ_STORAGE            zcl_az_blob_client, zif_az_blob_service, zcl_az_blob_udk_sas, blob models
│   ├── ZABAP_AZ_COMPUTE            zcl_az_compute_client, zif_az_compute_service
│   └── ZABAP_AZ_RESOURCEGRAPH      zcl_az_resourcegraph_client, zif_az_resourcegraph_service, RG models
├── ZABAP_AZ_TEST                   reusable test doubles + fixtures (zcl_az_http_client_mock, zcl_az_token_credential_fake, zcl_az_test_environment, zcl_az_test_env_request)
└── ZABAP_AZ_DEMO                   runnable example classes (zcl_az_demo_blob_ops, zcl_az_demo_compute_vm, zcl_az_demo_rg_quer)
```

Dictionary: table `zaz_config` (environment-credential configuration). Message classes: `zazure_auth`,
`zazure_error`, `zazure_http_error`.

---

## Getting started

### Prerequisites

- SAP BAIP ABAP Environment or S/4HANA Cloud (public/private) with **ABAP for Cloud Development**.
- Outbound HTTP connectivity / communication arrangement to the relevant Azure endpoints
  (`login.microsoftonline.com`, `management.azure.com`, `*.blob.core.windows.net`, IMDS for Managed Identity).
- An Azure identity. In order of preference: a **Microsoft Entra ID identity** (a service principal or a
  Managed Identity) — used both directly and to mint a User Delegation SAS — or, only if necessary, a
  SAS / account key for storage.

### Import

The repository is a file-system export of ABAP Development Tools (ADT) objects. Import it into your ABAP
Cloud system with ADT / abapGit, then activate. Activate the `ZABAP_AZ_CORE*` packages first (services
depend on them).

### Example — recommended: blob access with a User Delegation SAS

The recommended way to access blob data: a Microsoft Entra ID identity signs a short-lived,
identity-traceable SAS — no account key is involved.

```abap
DATA(lo_credential) = NEW zcl_az_client_secret_cred(   " a Microsoft Entra ID identity
    iv_client_id     = '<client-id>'
    iv_client_secret = '<client-secret>'
    iv_tenant_id     = '<tenant-id>' ).

DATA(lo_udk) = NEW zcl_az_blob_udk_sas(
    iv_account_name = '<storage-account>'
    io_credential   = lo_credential ).               " Entra ID identity signs the SAS

DATA(lo_blob) = lo_udk->create_blob_client(
    iv_container   = '<container>'
    iv_permissions = 'rl'                            " read + list
    iv_start       = '2026-07-24T00:00:00Z'
    iv_expiry      = '2026-07-25T00:00:00Z' ).

DATA(lo_result) = lo_blob->list_blobs( iv_container = '<container>' ).   " no account key
LOOP AT lo_result->mt_blobs INTO DATA(ls_blob).
  " ls_blob-name / ls_blob-content_type / ls_blob-content_length ...
ENDLOOP.
```

### Example — blob access with a direct Entra ID credential

Also fully supported: pass the Entra ID credential straight to the blob client (the identity needs a
*Storage Blob Data* RBAC role on the account).

```abap
DATA(lo_blob) = NEW zcl_az_blob_client(
    iv_account_name = '<storage-account>'
    io_credential   = lo_credential ).               " Microsoft Entra ID bearer token

DATA(lo_result) = lo_blob->list_blobs( iv_container = '<container>' ).
```

> Plain **SAS** (`iv_sas_token`) and **Shared Key** (`iv_account_key`) are also accepted by the constructor,
> but they are the least-recommended options — see
> [Storage data-plane auth — recommended order](#storage-data-plane-auth--recommended-order).

### Example — run a Resource Graph query

```abap
DATA(lo_rg) = NEW zcl_az_resourcegraph_client( io_credential = lo_credential ).

DATA(lo_result) = lo_rg->query_resources(
    iv_query         = `Resources | project name, type, location | limit 5`
    it_subscriptions = VALUE #( ( '<subscription-id>' ) ) ).
```

### Running the demos

The `ZABAP_AZ_DEMO` package contains three ready-to-run, self-contained example classes — one per service.
Each is an `if_oo_adt_classrun` class, so you run it directly from ABAP Development Tools with **F9**
(*Run As → ABAP Application (Console)*) and read the output in the console.

| Demo class | Service | What it does |
|------------|---------|--------------|
| `zcl_az_demo_blob_ops` | Storage Blob | **End-to-end document upload**: builds an in-memory PDF "invoice", uploads it to a container, lists blobs, and downloads it back. Demonstrates all auth modes (defaults to User Delegation SAS). |
| `zcl_az_demo_compute_vm` | Compute | Lists the VMs in a resource group and deallocates a VM. |
| `zcl_az_demo_rg_quer` | Resource Graph | Runs a KQL query three ways: the ergonomic facade, the typed `resources( body )`, and `operations_list`. |

**Before running**, open the demo class and replace the placeholder constants / credential values with your
own environment — every value to change is marked with a `<YOUR_...>` placeholder:

- `<YOUR_STORAGE_ACCOUNT>`, `<YOUR_CONTAINER>` (blob)
- `<YOUR_SUBSCRIPTION_ID>`, `<YOUR_RESOURCE_GROUP>`, `<YOUR_VM_NAME>` (compute)
- `<YOUR_CLIENT_ID>`, `<YOUR_TENANT_ID>`, `<YOUR_CLIENT_SECRET>` (the Entra ID service principal used to
  authenticate)

> The demos ship with **placeholders only** — never commit real credentials, account names, or SAS tokens
> back to source control. For production use, source the client secret from a secure store rather than
> hard-coding it, or switch the demo to Managed Identity (`zcl_az_managed_identity_cred`), which needs no
> secret at all.

The blob demo focuses on the **document round-trip**: `upload_blob` assembles a minimal valid PDF entirely
in memory (no external file needed) and uploads it as `invoice.pdf` with content type `application/pdf`. A
comment marks exactly where you would swap in real document bytes — e.g. a PDF rendered by the SAP Forms
service / `cl_fp*`, a spool request, or an ArchiveLink document.

---

## Design principles & conventions

- **Typed errors, not return codes** — every operation raises the `zcx_azure` hierarchy; callers use
  `TRY … CATCH zcx_azure`.
- **Per-service default scope** baked into each client (ARM = `https://management.azure.com/.default`,
  Storage = `https://storage.azure.com/.default`).
- **Content-type-aware payloads** — textual bodies (JSON/XML/text) transported as strings; binary bodies
  (octet-stream, images, …) as `xstring`, so binary blobs are never corrupted by a text decode.
- **No secrets in source** — credentials are injected at runtime; test fixtures use synthetic values and
  self-skip when unconfigured. `zcl_az_test_environment` keeps the client secret blank by default.
- **Cloud-released APIs only** — the runtime uses released classes (`cl_web_http_client`,
  `cl_abap_hmac`, `cl_web_http_utility`, `cl_abap_conv_codepage`, ixml, `/ui2/cl_json`) for
  ABAP-Cloud compatibility.

---

## Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide a CLA
and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions provided
by the bot. You will only need to do this once across all repos using our CLA.

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to build, test, and submit changes. In short: keep unit
tests `RISK LEVEL HARMLESS` using the provided doubles, put live checks in self-skipping integration
tests, and **never commit real credentials, account names, SAS tokens, or account keys.**

### Feedback

As an initial preview/MVP release, feedback is especially valuable. Please open a
**GitHub issue** to report bugs, request additional Azure services or operations, or suggest improvements
to the design and ergonomics. Real-world usage reports — what worked, what was missing — directly inform
the path to a stable 1.0.

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Security

Do not report security vulnerabilities through public GitHub issues. Please report them to the Microsoft
Security Response Center as described in [SECURITY.md](SECURITY.md).

**Never commit real client secrets, account keys, or SAS tokens.** Credentials belong in a secure store
and are injected at runtime; `zcl_az_test_environment` is the single place to plug local integration-test
values and must stay blank in source control.

## License

This project is licensed under the [MIT License](LICENSE).

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply
Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party's policies.
