# GitOps folder

This local folder is the "git repo" ArgoCD deploys from. No GitHub needed.

    apps/
      <app-name>/      one folder per application (folder name = app name = namespace)
        ...            everything that app needs

What goes inside an app folder:

    Helm app           Chart.yaml (wraps a public chart) + values.yaml (your settings)
    Plain YAML app     any number of *.yaml Kubernetes files

Workflow: edit files here, then run `lab sync`. ArgoCD picks the change up.
To add an app: create `apps/<name>/`, put files in it, run `lab sync`.
To remove an app: delete its folder, run `lab sync`.
Examples: apps/podinfo (Helm) and apps/hello-web (plain YAML).
