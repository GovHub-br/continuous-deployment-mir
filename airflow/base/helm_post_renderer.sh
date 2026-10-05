#!/bin/bash

cat <&0 > resources.yaml
# ok to use '--enable-helm' as we maintain the helm repository
kubectl kustomize . --enable-helm --load-restrictor LoadRestrictionsNone && rm resources.yaml
