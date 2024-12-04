IMAGE := avniproject/reporting-superset
TAG ?= 4.0.1

build-image:
	@echo "building image $(IMAGE):$(TAG)"
	docker image build --build-arg TAG=$(TAG) -t $(IMAGE):$(TAG) .

re-build-image:delete-image
	@echo "building image $(IMAGE):$(TAG)"
	docker image build --build-arg version=$(TAG) -t $(IMAGE):$(TAG) .

delete-image:
	@if docker image inspect $(IMAGE):$(TAG) > /dev/null 2>&1; then \
		echo "Image $(IMAGE):$(TAG) found. Deleting..."; \
		docker image rm -f $(IMAGE):$(TAG); \
	else \
		echo "Image $(IMAGE):$(TAG) not found."; \
	fi

push-image:
	@if [ -z "$(REPO_URI)" ]; then \
		echo "REPO_URI is not set"; \
		exit 1; \
	fi
	@if docker image inspect $(REPO_URI)/$(IMAGE):$(TAG) > /dev/null 2>&1; then \
		echo "Image $(REPO_URI)/$(IMAGE):$(TAG) found. deleting from the local"; \
		docker image rm -f $(IMAGE):$(TAG); \
	else \
		echo "Image $(REPO_URI)/$(IMAGE):$(TAG) not found in local."; \
	fi
	docker tag $(IMAGE):$(TAG) $(REPO_URI)/$(IMAGE):$(TAG)
	echo "pushing image $(REPO_URI)/$(IMAGE):$(TAG)";
	docker push $(REPO_URI)/$(IMAGE):$(TAG)

delete-repo-image:
	@if [ -z "$(REPO_URI)" ]; then \
		echo "REPO_URI is not set"; \
		exit 1; \
	fi
	docker image rm $(REPO_URI)/$(IMAGE):$(TAG)

inspect-image:
	docker image inspect $(IMAGE):$(TAG)

run-container:
	docker run -d -p 8088:8088 \
      --name superset_$(TAG) \
      --env-file superset.env \
      $(IMAGE):$(TAG)
	@$(MAKE) get-container-logs

remove-container:
	docker container rm -f superset_$(TAG)

get-container-logs:
	docker logs -f superset_$(TAG)

execute-container:
	docker container exec -it  superset_$(TAG) bash
