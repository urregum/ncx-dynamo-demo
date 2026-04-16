---
name: Bug report
about: Something broken in the demo environment
labels: bug
---

**Describe the bug**
A clear description of what went wrong.

**Make target**
Which target failed (e.g. `make gpu-deploy`, `make benchmark-same-rack`)?

**Environment**
- OS and version:
- Docker version (`docker --version`):
- Kind version (`kind --version`):
- NVIDIA driver version (GPU track only, `nvidia-smi`):
- GPU model (GPU track only):

**Steps to reproduce**
1.
2.
3.

**Actual behavior**
What happened, including any error output or pod logs.

**Expected behavior**
What you expected to happen.

**Logs**
For pod failures: `kubectl logs -n dynamo-demo <pod-name>`
For cluster issues: `make validate-cluster` output
