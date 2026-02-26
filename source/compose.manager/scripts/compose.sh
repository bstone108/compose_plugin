#!/bin/bash
export HOME=/root

SHORT=e:,c:,f:,p:,d:,o:,g:,r:,w:
LONG=env,command:,file:,project_name:,project_dir:,override:,profile:,retry-count:,retry-wait:,retry-rebuild,debug,recreate
OPTS=$(getopt -a -n compose --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

envFile=""
files=""
project_dir=""
options=""
command_options=""
debug=false
retry_count=0
retry_wait=10
retry_rebuild=false

while :
do
  case "$1" in
    -e | --env )
      envFile="$2"
      shift 2
      
      if [ -f $envFile ]; then
        echo "using .env: $envFile"
      else
        echo ".env doesn't exist: $envFile"
        exit
      fi

      envFile="--env-file ${envFile@Q}"
      ;;
    -c | --command )
      command="$2"
      shift 2
      ;;
    -f | --file )
      files="${files} -f ${2@Q}"
      shift 2
      ;;
    -p | --project_name )
      name="$2"
      shift 2
      ;;
    -d | --project_dir )
      if [ -d "$2" ]; then
        for file in $( find $2 -maxdepth 1 -type f -name '*compose*.yml' ); do
          files="$files -f ${file@Q}"
        done
      fi
      shift 2
      ;;
    -g | --profile )
      options="${options} --profile $2"
      shift 2
      ;;
    -r | --retry-count )
      retry_count="$2"
      shift 2
      ;;
    -w | --retry-wait )
      retry_wait="$2"
      shift 2
      ;;
    --retry-rebuild )
      retry_rebuild=true
      shift;
      ;;
    --recreate )
      command_options="${command_options} --force-recreate"
      shift;
      ;;
    --debug )
      debug=true
      shift;
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      ;;
  esac
done

normalize_non_negative_int() {
  local value="$1"
  local default="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo "$default"
  fi
}

run_compose_up() {
  local with_build="$1"
  local up_options="$command_options"
  if [ "$with_build" = true ]; then
    up_options="${up_options} --build"
  fi

  if [ "$debug" = true ]; then
    logger "docker compose $envFile $files $options -p "$name" up $up_options -d"
  fi

  eval docker compose $envFile $files $options -p "$name" up $up_options -d 2>&1
}

get_stack_container_ids() {
  eval docker compose $envFile $files $options -p "$name" ps -q 2>/dev/null
}

stack_all_containers_running() {
  local container_ids
  local container_id
  local status
  local health
  container_ids=$(get_stack_container_ids)

  if [ -z "$container_ids" ]; then
    return 1
  fi

  while IFS= read -r container_id; do
    if [ -z "$container_id" ]; then
      continue
    fi

    status=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null)
    if [ "$status" != "running" ] || [ "$health" = "unhealthy" ]; then
      return 1
    fi
  done <<< "$container_ids"

  return 0
}

stack_start_in_progress() {
  local container_ids
  local container_id
  local status
  local health
  container_ids=$(get_stack_container_ids)

  if [ -z "$container_ids" ]; then
    return 1
  fi

  while IFS= read -r container_id; do
    if [ -z "$container_id" ]; then
      continue
    fi

    status=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null)
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null)
    if [ "$status" = "created" ] || [ "$status" = "restarting" ] || [ "$health" = "starting" ]; then
      return 0
    fi
  done <<< "$container_ids"

  return 1
}

wait_for_stack_start_completion() {
  local poll_seconds=2
  local waited=0

  while stack_start_in_progress; do
    if [ "$waited" -eq 0 ]; then
      echo "Compose services are still starting from the previous attempt. Waiting for that attempt to finish..."
    fi
    sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
    if [ $((waited % 30)) -eq 0 ]; then
      echo "Still waiting on previous compose attempt (${waited}s elapsed)..."
    fi
  done
}

retry_count=$(normalize_non_negative_int "$retry_count" "0")
retry_wait=$(normalize_non_negative_int "$retry_wait" "10")

case $command in

  up)
    run_compose_up false
    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      exit 0
    fi

    if [ "$retry_count" -eq 0 ]; then
      exit "$exit_code"
    fi

    if stack_all_containers_running; then
      echo "Compose services are already running. Skipping retries."
      exit 0
    fi

    wait_for_stack_start_completion
    if stack_all_containers_running; then
      echo "Compose services are already running. Skipping retries."
      exit 0
    fi

    for (( attempt=1; attempt<=retry_count; attempt++ )); do
      wait_for_stack_start_completion
      if stack_all_containers_running; then
        echo "Compose services are already running. Skipping remaining retries."
        exit 0
      fi

      if [ "$retry_wait" -gt 0 ]; then
        echo "Compose up failed. Retrying (${attempt}/${retry_count}) in ${retry_wait} seconds..."
        sleep "$retry_wait"
      else
        echo "Compose up failed. Retrying (${attempt}/${retry_count})..."
      fi

      wait_for_stack_start_completion
      if stack_all_containers_running; then
        echo "Compose services are already running. Skipping remaining retries."
        exit 0
      fi

      retry_with_build=false
      if [ "$retry_rebuild" = true ] && [ "$attempt" -eq "$retry_count" ]; then
        retry_with_build=true
        echo "Last retry is using --build."
      fi

      run_compose_up "$retry_with_build"
      exit_code=$?
      if [ "$exit_code" -eq 0 ]; then
        exit 0
      fi

      if stack_all_containers_running; then
        echo "Compose services are already running. Skipping remaining retries."
        exit 0
      fi

      wait_for_stack_start_completion
    done

    exit "$exit_code"
    ;;

  down)
    if [ "$debug" = true ]; then
      logger "docker compose $envFile $files $options -p "$name" down"
    fi
    eval docker compose $envFile $files $options -p "$name" down  2>&1
    ;;
    
  update)
    if [ "$debug" = true ]; then
      logger "docker compose $envFile $files $options -p "$name" images -q"
      logger "docker compose $envFile $files $options  -p "$name" pull"
      logger "docker compose $envFile $files $options -p "$name" up -d --build"
    fi

    images=()
    images+=( $(docker compose $envFile $files $options -p "$name" images -q) )

    if [ ${#images[@]} -eq 0 ]; then   
      delete="-f"
      files_arr=( $files ) 
      files_arr=( ${files_arr[@]/$delete} )
      if (( ${#files_arr[@]} )); then
        services=( $(cat ${files_arr[*]//\'/} | sed -n 's/image:\(.*\)/\1/p') )

        for image in "${services[@]}"; do
          images+=( $(docker images -q --no-trunc ${image}) )
        done
      fi

      images=( ${images[*]##sha256:} )
    fi
    
    eval docker compose $envFile $files $options -p "$name" pull 2>&1
    eval docker compose $envFile $files $options -p "$name" up -d --build 2>&1
    # eval docker compose $envFile $files $options -p "$name" up -d --build 2>&1

    new_images=( $(docker compose $envFile $files $options -p "$name" images -q) )
    for target in "${new_images[@]}"; do
      for i in "${!images[@]}"; do
        if [[ ${images[i]} = $target ]]; then
          unset 'images[i]'
        fi
      done
    done

    if (( ${#images[@]} )); then
      if [ "$debug" = true ]; then
        logger "docker rmi ${images[*]}"
      fi
      eval docker rmi ${images[*]}
    fi
    ;;

  stop)
    if [ "$debug" = true ]; then
      logger "docker compose $envFile $files $options -p "$name" stop"
    fi
    eval docker compose $envFile $files $options -p "$name" stop  2>&1
    ;;

  list) 
    if [ "$debug" = true ]; then
      logger "docker compose ls -a --format json"
    fi
    eval docker compose ls -a --format json 2>&1
    ;;

  logs)
    if [ "$debug" = true ]; then
      logger "docker compose $envFile $files $options logs -f"
    fi
    eval docker compose $envFile $files $options logs -f 2>&1
    ;;

  *)
    echo "unknown command"
    echo $command 
    echo $name 
    echo $files
    ;;
esac
