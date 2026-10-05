#!/bin/bash

cat <&0 > resources.yaml
kubectl kustomize . --enable-helm --load-restrictor LoadRestrictionsNone && rm resources.yaml
