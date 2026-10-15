## 📝 Summary
<!-- What does this PR do, in one or two sentences? -->

## 🔗 Related issue
<!-- e.g. Closes #123 -->

## 🧩 Type of change
- [ ] 🐛 Bug fix
- [ ] ✨ New feature
- [ ] 📚 Documentation / portfolio page
- [ ] ♻️ Refactor (no behaviour change)
- [ ] 🔧 CI / tooling

## 🎯 Area
- [ ] `lab.sh` / `lab.env`
- [ ] Jenkins
- [ ] ArgoCD / `gitops/`
- [ ] Monitoring
- [ ] Docs / portfolio

## 🧪 How I tested
<!-- Commands you ran and what you saw. Paste the final `lab status` table if relevant. -->
- [ ] `bash -n lab.sh` and `shellcheck lab.sh`
- [ ] `./lab.sh destroy && ./lab.sh up` on macOS
- [ ] `lab sync` shows my change in ArgoCD (if `gitops/` changed)

## 📸 Screenshots / output (optional)

## ✅ Checklist
- [ ] Generated config changes were made inside `write_configs` in `lab.sh`, not in the generated files
- [ ] New settings are added to `lab.env.example`
- [ ] README / docs updated
- [ ] CHANGELOG.md updated under Unreleased
- [ ] No passwords or kubeconfigs are committed

## ⚠️ Breaking changes / migration
<!-- e.g. "ports changed, run `lab destroy` then `lab up`". Write "None" if not applicable. -->
