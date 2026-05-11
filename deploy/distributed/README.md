# Distributed SIEM Deployment

Control entrypoint:

```bash
bash deploy/distributed/siemctl.sh <command>
```

Common flow:

```bash
bash deploy/distributed/siemctl.sh tune
bash deploy/distributed/siemctl.sh up
bash deploy/distributed/siemctl.sh bootstrap
bash deploy/distributed/siemctl.sh validate
bash deploy/distributed/siemctl.sh benchmark distributed-1m
bash deploy/distributed/siemctl.sh benchmark distributed-3m
```

See `docs/distributed-deployment.md` for the full runbook.
