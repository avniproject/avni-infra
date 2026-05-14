IMAGE := avniproject/tanuh-metabase
TAG ?= $(shell cat VERSION)
# Upstream Metabase release we build on top of (strips the -tanuh-N suffix).
METABASE_VERSION ?= $(shell echo $(TAG) | sed 's/-tanuh-.*//')

# Source build is heavy (~30–60 min). Enable BuildKit so cache mounts and
# parallel stages work; use buildx in CI for layer caching across runs.
export DOCKER_BUILDKIT=1

build-image:
	@echo "building image $(IMAGE):$(TAG) (Metabase source $(METABASE_VERSION))"
	docker image build --build-arg METABASE_VERSION=$(METABASE_VERSION) -t $(IMAGE):$(TAG) .

re-build-image: delete-image
	@echo "rebuilding image $(IMAGE):$(TAG)"
	docker image build --build-arg METABASE_VERSION=$(METABASE_VERSION) -t $(IMAGE):$(TAG) .

delete-image:
	@if docker image inspect $(IMAGE):$(TAG) > /dev/null 2>&1; then \
		echo "Image $(IMAGE):$(TAG) found. Deleting..."; \
		docker image rm -f $(IMAGE):$(TAG); \
	else \
		echo "Image $(IMAGE):$(TAG) not found."; \
	fi

push-image:
	@if [ -z "$(REPO_URI)" ]; then \
		echo "REPO_URI is not set (e.g. 118388513628.dkr.ecr.ap-south-1.amazonaws.com)"; \
		exit 1; \
	fi
	docker tag $(IMAGE):$(TAG) $(REPO_URI)/$(IMAGE):$(TAG)
	@echo "pushing image $(REPO_URI)/$(IMAGE):$(TAG)"
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
	docker run -d -p 3000:3000 \
		--name tanuh_metabase_$(TAG) \
		--env-file tanuh_metabase.env \
		$(IMAGE):$(TAG)
	@$(MAKE) get-container-logs

remove-container:
	docker container rm -f tanuh_metabase_$(TAG)

get-container-logs:
	docker logs -f tanuh_metabase_$(TAG)

execute-container:
	docker container exec -it tanuh_metabase_$(TAG) bash
