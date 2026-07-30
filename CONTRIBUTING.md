# Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## How to contribute

This repository is a file-system export of ABAP Development Tools (ADT) objects for an ABAP Cloud SDK.

1. **Fork** the repository and create a topic branch from `main`.
2. **Develop in ABAP Cloud** — import the objects into an SAP BAIP ABAP Environment / S/4HANA Cloud system
   (ABAP for Cloud Development, language version 5) via ADT or abapGit.
3. **Follow the existing conventions** (see the "Design principles & conventions" section of the README):
   typed `zcx_azure` exceptions, the pipeline/policy pattern, the `io_http_client` injection seam, and
   cloud-released APIs only.
4. **Add ABAP Unit tests** for any new behaviour. Keep unit tests `RISK LEVEL HARMLESS DURATION SHORT`
   (no network) using the provided doubles (`zcl_az_http_client_mock`, `zcl_az_token_credential_fake`);
   put live checks in self-skipping integration tests. Never commit real credentials, account names,
   SAS tokens, or account keys.
5. **Run the full ABAP Unit suite** and ensure it is green before opening a pull request.
6. **Open a pull request** with a clear description of the change and the tests you added or ran.
