.PHONY: help shared-init shared-plan shared-apply prod-init prod-bootstrap prod-plan prod-apply prod-apply-dns kubeconfig lb-ip apply-issuer

LETSENCRYPT_EMAIL ?= damien.marque.dm@gmail.com

help:
	@echo "Étapes pour bootstrapper la plateforme Kapsule mutualisée :"
	@echo ""
	@echo "  1. make shared-init && make shared-apply"
	@echo "     → projet Scaleway + bucket state + Container Registry"
	@echo ""
	@echo "  2. cd shared && terraform output -raw project_id"
	@echo "     → reporter la valeur dans envs/prod/terraform.tfvars"
	@echo ""
	@echo "  3. make prod-init"
	@echo "  4. make prod-bootstrap   # cluster + pool (provider K8s n'est pas encore activable)"
	@echo "  5. make prod-apply       # ajoute Postgres, Helm releases, namespaces, secrets"
	@echo "  6. make apply-issuer     # ClusterIssuer cert-manager (après installation des CRDs)"
	@echo "  7. make lb-ip            # IP publique du LoadBalancer Ingress"
	@echo "  8. make prod-apply-dns   # records OVH pointant sur l'IP du LB"
	@echo ""
	@echo "  Pour utiliser kubectl :"
	@echo "    make kubeconfig > ~/.kube/mairie-agglo-prod.yaml"
	@echo "    export KUBECONFIG=~/.kube/mairie-agglo-prod.yaml"

shared-init:
	cd shared && terraform init

shared-plan:
	cd shared && terraform plan

shared-apply:
	cd shared && terraform apply

prod-init:
	cd envs/prod && terraform init

prod-bootstrap:
	cd envs/prod && terraform apply \
		-target=scaleway_vpc.this \
		-target=scaleway_vpc_private_network.this \
		-target=scaleway_k8s_cluster.this \
		-target=scaleway_k8s_pool.default \
		-target=scaleway_rdb_instance.shared

prod-plan:
	cd envs/prod && terraform plan

prod-apply:
	cd envs/prod && terraform apply

prod-apply-dns:
	cd envs/prod && terraform apply -var enable_dns_records=true

kubeconfig:
	@cd envs/prod && terraform output -raw kubeconfig

lb-ip:
	@TMPKUBE=$$(mktemp) && \
	cd envs/prod && terraform output -raw kubeconfig > $$TMPKUBE && \
	kubectl --kubeconfig=$$TMPKUBE get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo && \
	rm -f $$TMPKUBE

apply-issuer:
	@TMPKUBE=$$(mktemp) && \
	cd envs/prod && terraform output -raw kubeconfig > $$TMPKUBE && \
	cd .. && \
	sed "s/REMPLACER_EMAIL/$(LETSENCRYPT_EMAIL)/" ../scripts/cert-manager-issuer.yaml | \
	kubectl --kubeconfig=$$TMPKUBE apply -f - && \
	rm -f $$TMPKUBE
