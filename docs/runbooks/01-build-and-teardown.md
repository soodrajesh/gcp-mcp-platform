# 1. Build and tear down

```bash
gcloud config set project <your-project>   # billing linked; the rest is auto-detected
./scripts/up.sh                            # ~10 min including the live test suite
./scripts/up.sh --skip-tests               # infra + image only
./scripts/down.sh                          # destroy everything
```

Prerequisites: `gcloud`, `terraform`, `bq`, `python3`, `curl`, `jq`.

`up.sh` runs: state bucket → Terraform phase 1 (Firestore, audit sink, identities, alerts, registry) →
unit tests → Cloud Build image → Terraform phase 2 (the two Cloud Run services) → a smoke call as the
operator → `test.sh`.

Cost: scales to zero; Firestore and BigQuery usage in the tests is far below free-tier limits.
