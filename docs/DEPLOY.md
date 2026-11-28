# Deploy: the core `@osprey` account

How to set up the organization and the person that release the core `@osprey` packages on <https://packages.ospreylang.dev>.

**One way in.** A package version is released by a signed intent for a commit in the package's bound GitHub repository; the registry fetches that commit itself ([`[PACKAGE-HOSTED-PUBLISH-FLOW]`](specs/ecosystem/PackageRegistryDeploymentAndOwnership.md#releasing-from-a-github-repository-package-hosted-publish-flow)). Nothing is uploaded and no operator seeds a package.

✅ = built and tested on the branch, live after the next release from `main`. 🚧 = not built yet; the step cannot be done until it is.

## 1. The user

- [ ] ✅ Open `/register/` and choose **Continue with GitHub**, using the GitHub account that will keep `@osprey`. The first sign-in creates the registry account.
- [ ] 🚧 Enrol a passkey on that account. It becomes the default sign-in and is the credential that signs every release.

## 2. The organization

Do this before the site is announced: a handle goes to the first account that asks for it.

- [ ] ✅ Create the organization with handle `osprey`. The signed-in user becomes its custodian.
  - API: `POST /v1/organizations` with `{"handle":"osprey","name":"Osprey"}` → `{"id"}`
  - 🚧 No form on the website yet.

## 3. The packages

- [ ] ✅ Create each core package in the organization. Its creator is the package's administrator and holds `publish-release`.
  - API: `POST /v1/organizations/{id}/packages` with `{"name":"json"}` → `{"id"}`
  - 🚧 No form on the website yet.
- [ ] 🚧 Bind each package to its source: install the registry's GitHub App on `Nimblesite/osprey` only, then enrol the repository, the package's subdirectory and branch `main`.

## 4. The reviewer

- [ ] 🚧 Make the user a release reviewer. Owning a package grants no review authority, and production has no way to appoint the first reviewer yet.

## 5. Release

- [ ] 🚧 On `/release/`, choose the package, paste the full 40-character commit hash and sign with the passkey. The registry fetches, freezes and scans the commit.
- [ ] ✅ Approve the scanned version on its receipt. The catalog then lists it.

## 6. Check

- [ ] `curl https://packages-api.ospreylang.dev/v1/packages` lists `@osprey/<name>`.
- [ ] `osprey-pkg lock` then `osprey-pkg fetch` in a fresh project that depends on it.

Deploying the registry itself: [ops README](../src/manager/ops/README.md).
