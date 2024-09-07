IMAGE := vedfordocker/superset
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
	docker push $(IMAGE):$(TAG)


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
