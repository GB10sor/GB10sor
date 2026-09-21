# Contributing

1. Do not include credentials, serial numbers, private hostnames, private addresses, local account paths, or raw qualification evidence.
2. Pin external sources, checkpoint revisions, and images.
3. Keep model weights outside Git.
4. Keep development shells inert and model APIs on loopback.
5. Treat changed weights, images, flags, drivers, or source revisions as a new qualification candidate.

Before proposing a change, run:

```bash
./VERIFY.command
nix flake show --no-write-lock-file
```

Unless a file says otherwise, contributions are accepted under Apache-2.0.
