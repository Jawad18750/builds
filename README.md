# builds

Build runners. This repository holds workflows and helper scripts only: no source code,
no keys, no configuration.

- Source is fetched at run time with read-only access, and nothing is kept afterwards.
- Credentials come from encrypted repository secrets and are removed when a job ends.
- Runs are started by hand by the maintainer. Pull requests and forks cannot reach the
  secrets.

Logs are public, so no step may print a secret, a credential or anything personal.

Not open to contributions.
