#!/bin/bash

# Copyright 2017 Google Inc.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# The script has two modes it can run in:
# - run_test: 		Run the test cmd in the given Docker image ("flavor").
# - create_cache:  	Create a new Docker image after copying the source and
#					running "make build". Such an image can be reused in
#					future test invocations via --use_docker_cache <image>.
mode="run_test"

# Parse non-positional flags.
while true ; do
  case "$1" in
    --create_docker_cache)
	    case "$2" in
	        "")
	          echo "ERROR: --create_docker_cache requires the name of the image as second parameter"
	          exit 1
	          ;;
	        *)
	          mode="create_cache"
	          cache_image=$2
	          shift 2
	          ;;
	    esac ;;
    --use_docker_cache)
        case "$2" in
            "")
              echo "ERROR: --use_docker_cache requires the name of the image as second parameter"
              exit 1
              ;;
            *)
              existing_cache_image=$2
              shift 2
              ;;
        esac ;;
    -*)
      echo "ERROR: Unrecognized flag: $1"
      exit 1
      ;;
    *)
      # No more non-positional flags.
      break
      ;;
	esac
done

flavor=$1
cmd=$2
args=

if [[ -z "$flavor" ]]; then
  echo "Flavor must be specified as first argument."
  exit 1
fi

if [[ -z "$cmd" ]]; then
  cmd=bash
fi

if [[ ! -f bootstrap.sh ]]; then
  echo "This script should be run from the root of the Vitess source tree - e.g. ~/src/github.com/youtube/vitess"
  exit 1
fi

image=vitess/bootstrap:$flavor
if [[ -n "$existing_cache_image" ]]; then
  image=$existing_cache_image
fi

# To avoid AUFS permission issues, files must allow access by "other" (permissions rX required).
# Mirror permissions to "other" from the owning group (for which we assume it has at least rX permissions).
chmod -R o=g .

args="$args -v /dev/log:/dev/log"
args="$args -v $PWD:/tmp/src"

# Share maven dependency cache so they don't have to be redownloaded every time.
mkdir -p /tmp/mavencache
chmod 777 /tmp/mavencache
args="$args -v /tmp/mavencache:/home/vitess/.m2"

# Mount in host VTDATAROOT if one exists, since it might be a RAM disk or SSD.
if [[ -n "$VTDATAROOT" ]]; then
  hostdir=`mktemp -d $VTDATAROOT/test-XXX`
  testid=`basename $hostdir`

  chmod 777 $hostdir

  echo "Mounting host dir $hostdir as VTDATAROOT"
  args="$args -v $hostdir:/vt/vtdataroot --name=$testid -h $testid"
else
  testid=test-$$
  args="$args --name=$testid -h $testid"
fi

# Run tests
case "$mode" in
  "run_test") echo "Running tests in $image image..." ;;
  "create_cache") echo "Creating cache image $cache_image ..." ;;
esac

# TODO(mberlin): Copy vendor/vendor.json file such that we can run a diff against the file on the image.
# TODO(mberlin): Remove debug statement.
# Copy the full source tree except:
# - php/vendor
# - vendor
# That's because these directories are already part of the image.
#
# Note that we're using the Bash extended Glob support "(!php|vendor)" on
# purpose here to minimize the size of the cache image: With this trick,
# we do not move or overwrite the existing files while copying the other
# directories. Therefore, the existing files do not count as changed.
copy_src_cmd="cp -R /tmp/src/!(php|vendor) . && cp -R /tmp/src/php/!(vendor) php/ && cp -R /tmp/src/.git ."
bashcmd="set -x"
if [[ -z "$existing_cache_image" ]]; then
  bashcmd+=" && $copy_src_cmd"
fi
# At the end, run the actual command.
bashcmd+=" && $cmd"

# 529 MB = make build
# 468 MB = make build + rm alles ausser vendor
# 411 MB = make build + rm src + rm pkg
# 625 MB = make build + src + pkg + .git

if tty -s; then
  # interactive shell
  set -x
  docker run -ti $args $image bash -O extglob -c "$bashcmd"
  exitcode=$?
else
  # non-interactive shell (kill child on signal)
  trap 'docker kill $testid &>/dev/null' SIGTERM SIGINT
  docker run $args $image bash -O extglob -c "$bashcmd" &
  wait $!
  exitcode=$?
  trap - SIGTERM SIGINT
fi

# Clean up host dir mounted VTDATAROOT
if [[ -n "$hostdir" ]]; then
  # Use Docker user to clean up first, to avoid permission errors.
  docker run --name=rm_$testid -v $hostdir:/vt/vtdataroot $image bash -c 'rm -rf /vt/vtdataroot/*'
  docker rm -f rm_$testid &>/dev/null
  rm -rf $hostdir
fi

if [[ "$mode" == "create_cache" && $exitcode == 0 ]]; then
  msg="DO NOT PUSH: This is a temporary layer meant to persist e.g. the result of 'make build'. Never push this layer back to our official Docker Hub repository."
  docker commit -m "$msg" $testid $cache_image

  if [[  $? != 0 ]]; then
    exitcode=$?
    echo "ERROR: Failed to create Docker cache. Used command: docker commit -m '$msg' $testid $image"
  fi
fi

# Delete the container
docker rm -f $testid &>/dev/null

exit $exitcode
