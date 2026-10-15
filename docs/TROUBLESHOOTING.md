# Troubleshooting

## "Port N is already in use"
Something on your Mac already listens there.
```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN     # who owns it
```
Stop it, or change the port in the SETTINGS block of `lab.sh`.

## "Existing cluster uses an older port layout"
kind cannot change ports on a live cluster:
```bash
lab destroy
lab up
```

## Everything is slow or pods are Pending
Docker needs about 8 GB RAM. Raise it in Docker Desktop > Settings > Resources, then `lab stop && lab start`.

## Jenkins is not answering
```bash
docker logs -f lab-jenkins
```
The first boot takes 2-4 minutes. If it keeps failing, check that `jenkins_wp/` is writable.

## Jenkins cannot reach the cluster
Refresh its kubeconfig (this also happens on every `lab start`):
```bash
lab start
docker exec lab-jenkins kubectl get nodes
```

## ArgoCD password is "(see lab status)" or login fails
The initial secret is deleted once you change the admin password, so the lab can no longer read it. Log in with the password you set. If you forgot it, the quickest fix is to reinstall ArgoCD:
```bash
helm -n argocd uninstall argocd
kubectl delete ns argocd
lab up        # installs ArgoCD again with a fresh generated password
```

## `argocd` CLI says it cannot connect
The server runs in plain HTTP mode. Use:
```bash
argocd login localhost:8081 --plaintext --grpc-web
```

## Reset one tool only
```bash
helm -n argocd uninstall argocd && lab up        # re-installs ArgoCD
docker rm -f lab-jenkins && lab start            # recreates Jenkins, keeps jenkins_wp
```

## Start completely fresh
```bash
lab destroy --purge && lab up
```
