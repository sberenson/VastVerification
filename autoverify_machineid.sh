#!/bin/bash

# Function to display usage information
usage() {
    echo "Usage: $0 [--ignore-requirements] <machine_id>"
    echo "  --ignore-requirements: Optional switch to ignore the minimum search requirements check and run tests regardless."
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install a package if it's not already installed
install_if_missing() {
    if ! command_exists "$1"; then
        echo "$1 is not installed. Installing..."
        if [ "$needs_update" = true ]; then
            sudo apt-get update
            needs_update=false
        fi
        sudo apt-get install -y "$1"
    fi
}

# Function to check and update dependencies
check_and_update_dependencies() {
    local required_version="$1"
    local version_file="version.ini"
    local download_url="https://github.com/sberenson/VastVerification/releases/download/$required_version"

    # Check if version.ini exists and read the current version
    if [ -f "$version_file" ]; then
        current_version=$(<"$version_file")
    else
        current_version="none"
    fi

    # Compare versions and update if necessary
    if [ "$current_version" != "$required_version" ]; then
        echo "Updating dependencies to version $required_version..."

        # List of files to download
        local files=(
            "machinetester.sh"
            "check_machine_requirements.sh"
            "destroy_all_instances.sh"
            "get_port_from_instance_id.py"
            "https_client.py"
        )

        # Download each file
        for file in "${files[@]}"; do
            echo "Downloading $file..."
            curl -LO "$download_url/$file"
            
            if [ $? -eq 0 ]; then
                echo "$file downloaded successfully."
                chmod +x "$file"
                echo "$file is now executable."
            else
                echo "Failed to download $file. Exiting script."
                exit 1
            fi
        done

        # Update the version file
        echo "$required_version" > "$version_file"
        echo "Updated $version_file to version $required_version."
    else
        echo "Dependencies are up to date."
    fi
}

# Check and install jq and nc if they are not installed
install_if_missing "jq"
install_if_missing "netcat"
install_if_missing "bc"

# Check for --ignore-requirements switch
ignore_requirements=false
if [ "$1" == "--ignore-requirements" ]; then
    ignore_requirements=true
    shift # Shift the arguments to the left to remove the switch from the list
fi

# Check if exactly one argument (machine_id) is provided
if [ "$#" -ne 1 ]; then
    usage
fi

# Assign the machine_id to a variable
machine_id=$1

# Define the required version
required_version="v0.1.0-alpha"  # Update this version as needed

# Check and update dependencies
check_and_update_dependencies "$required_version"

# URLs of the files to check and download (this part remains the same)
URLS=(
    "https://github.com/sberenson/VastVerification/releases/download/$required_version/machinetester.sh"
    "https://github.com/sberenson/VastVerification/releases/download/$required_version/check_machine_requirements.sh"
    "https://github.com/sberenson/VastVerification/releases/download/$required_version/destroy_all_instances.sh"
    "https://github.com/sberenson/VastVerification/releases/download/$required_version/get_port_from_instance_id.py"
    "https://github.com/sberenson/VastVerification/releases/download/$required_version/https_client.py"
)

# Loop through each URL
for URL in "${URLS[@]}"; do
    FILE=$(basename "$URL")
    if [ -f "$FILE" ]; then
        echo -n ""
    else
        echo "Downloading $FILE..."
        curl -LO "$URL"

        if [ $? -eq 0 ]; then
            echo "$FILE downloaded successfully."
            chmod +x "$FILE"
            echo "$FILE is now executable."
        else
            echo "Failed to download $FILE. Exiting script."
            exit 1
        fi
    fi
done
# Continue with other operations (e.g., starting tests) here

# Always check machine requirements
./check_machine_requirements.sh "$machine_id"
result=$?

# If requirements are not met and --ignore-requirements is not set, exit
if [ $result -ne 0 ] && [ "$ignore_requirements" = false ]; then
    echo "Machine search requirements check failed. Ensure the machine is listed and meets the above requirements add --ignore-requirements to to ingore this and run the test if possible. Exiting."
    exit 1
fi

# Continue with other operations if the check passes or --ignore-requirements is set
if [ $result -eq 0 ]; then
    echo "Machine search requirements met. Continuing with the script."
else
    echo "Ignoring machine search requirements failure and continuing with the script. This might not work."
fi



echo "Starting tests for machine_id: $machine_id"


declare -A machine_ids
declare -A public_ipaddrs
declare -a active_instance_id
declare -A start_times  # Declare an associative array to store start times
declare -A CreateTime

function update_machine_id_and_ipaddr {
  local retries=3
  local json_output=""
  local instances=()
  local success=0

  # Attempt to get a valid response up to 3 times
  for (( i=1; i<=$retries; i++ )); do
    json_output=$(./vast show instances --raw)

    # Check if the JSON output can be parsed by jq
    if echo "$json_output" | jq -e . >/dev/null 2>&1; then
      success=1
      break
    else
      echo "Failed to parse JSON response (attempt $i of $retries). Retrying..."
      sleep 1
    fi
  done

  # If all retries failed
  if [[ $success -eq 0 ]]; then
    echo "Failed to get a valid JSON response after $retries attempts."
    return 1
  fi

  # Convert the JSON array to a Bash array
  mapfile -t instances < <(echo "$json_output" | jq -r '.[] | @base64')

  # Now we can loop over the instances array
  for instance in "${instances[@]}"; do
    # Decode the instance from base64 back to JSON
    instance_json=$(echo "$instance" | base64 --decode)

    # Extract the instance_id, machine_id, and public_ipaddr from the JSON
    instance_id=$(echo "$instance_json" | jq -r '.id')
    machine_id=$(echo "$instance_json" | jq -r '.machine_id')
    public_ipaddr=$(echo "$instance_json" | jq -r '.public_ipaddr')

    # Add the machine_id and public_ipaddr to the associative arrays
    machine_ids["$instance_id"]="$machine_id"
    public_ipaddrs["$instance_id"]="$public_ipaddr"
  done

}



function get_machine_id {
  local instance_id=$1

  # Check if the machine_id is in the associative array
  if [ -z "${machine_ids[$instance_id]}" ]; then
    # If not, update the associative arrays
    update_machine_id_and_ipaddr
  fi

  # Now the machine_id should be in the associative array, so we can return it
  echo "${machine_ids[$instance_id]}"
}

function get_public_ipaddr {
  local instance_id=$1

  # Check if the public_ipaddr is in the associative array
  if [ -z "${public_ipaddrs[$instance_id]}" ]; then
    # If not, update the associative arrays
    update_machine_id_and_ipaddr
  fi
  # Now the public_ipaddr should be in the associative array, so we can return it
  echo "${public_ipaddrs[$instance_id]}"
}


function get_status_msg {
  local id=$1
  local retries=3
  local success=0
  local json_output=""
  local instances=()

  # Attempt to get a valid response up to 3 times
  for (( i=1; i<=$retries; i++ )); do
    json_output=$(./vast show instances --raw)

    # Check if the JSON output can be parsed by jq
    if echo "$json_output" | jq -e . >/dev/null 2>&1; then
      success=1
      break
    else
      echo "Failed to parse JSON response (attempt $i of $retries). Retrying..."
      sleep 2
    fi
  done

  # If all retries failed
  if [[ $success -eq 0 ]]; then
    echo "Failed to get a valid JSON response after $retries attempts."
    return 1
  fi

  # Convert the JSON array to a Bash array
  mapfile -t instances < <(echo "$json_output" | jq -r '.[] | @base64')

  # Now we can loop over the instances array
  for instance in "${instances[@]}"; do
    # Decode the instance from base64 back to JSON
    instance_json=$(echo "$instance" | base64 --decode)

    # Extract the ID from the JSON
    instance_id=$(echo "$instance_json" | jq -r '.id')

    # If this is the instance were looking for
    if [ "$instance_id" = "$id" ]; then
      # Extract and print the status message
      status_msg=$(echo "$instance_json" | jq -r '.status_msg')
      echo "$status_msg"
      return
    fi
  done

  echo "No instance with ID $id found."
}

#check if the instances exist 
function search_instance  {
    local target_id="$1"
    local max_retries=4
    local retry_count=0
    local instances
    local found="false"

    while [ $retry_count -lt $max_retries ]; do
        instances=$(./vast show instances --raw)
        # Exit if the command fails
        if [ $? -ne 0 ]; then
            echo "Error retrieving instances"
            exit 1
        fi

        # Check if the ID exists using jq
        id_exists=$(echo "$instances" | jq --arg TARGET "$target_id" 'any(.[]; .id == ($TARGET|tonumber))')

        if [ "$id_exists" == "true" ]; then
            found="true"
            break
        fi

        ((retry_count++))
	sleep 10
    done

    echo "$found"
}





function get_actual_status {
  id=$1

  # Retry up to 3 times
  for attempt in {1..3}; do
    # Run the command and save the output
    json_output=$(./vast show instances --raw 2>error.log)

    # Check the return status of the command
    if [ $? -ne 0 ]; then
      echo "unknown"
      sleep 1
      continue
    fi

    if [[ -z "$json_output" ]]; then
      echo "No JSON output from command"
      sleep 1
      continue
    fi

    # Convert the JSON array to a Bash array
    mapfile -t instances < <(echo "$json_output" | jq -r '.[] | @base64')

    # Now we can loop over the instances array
    for instance in "${instances[@]}"; do
      # Decode the instance from base64 back to JSON
      instance_json=$(echo "$instance" | base64 --decode)

      # Extract the ID from the JSON
      instance_id=$(echo "$instance_json" | jq -r '.id')

      # If this is the instance were looking for
      if [ "$instance_id" = "$id" ]; then
        # Extract and print the actual_status
        actual_status=$(echo "$instance_json" | jq -r 'if .actual_status != null then .actual_status else "unknown" end')
        echo "$actual_status"
        return
      fi
    done

    # If we got here, it means we've successfully processed the JSON without issues, so we break out of the retry loop.
    break
  done

  # If the function hasn't returned by this point, we've failed all 3 attempts
  echo "unknown"
}


#****************************** start of main prcess ********

# create all the instances as needed
#Offers=($(./vast search offers 'verified=false cuda_vers>=12.0  gpu_frac=1 reliability>0.90 direct_port_count>3 pcie_bw>3 inet_down>10 inet_up>10 gpu_ram>5'  -o 'dlperf-'  | sed 's/|/ /'  | awk '{print $1}' )) # get all the instanses number from vast
#unset Offers[0] #delte the first index as it contains the title
./destroy_all_instances.sh "$1"


# Fetch data from the system
tempOffers=($(./vast search offers "machine_id=$1 verified=any"  -o 'dlperf-'  | sed 's/|/ /'  | awk '{print $1,$11,$19,$20}'))



# Delete the first index as it contains the title
echo "offers: $tempOffers"

#unset tempOffers[0]
#unset tempOffers[1]
#unset tempOffers[2]
#unset tempOffers[3]



# Declare associative arrays
declare -A maxDLPs
declare -A maxIDsWithMaxDLPs
declare -A uniqueMachIDs

echo '' > mach_id_list.txt
echo '' > maxIDsWithMaxDLPs.txt


# Parse the tempOffers array
for ((i=4; i<${#tempOffers[@]}; i+=4)); do
    id=${tempOffers[i]}
    dlp=${tempOffers[i+1]}
    mach_id=${tempOffers[i+2]}
    status=${tempOffers[i+3]}

    echo "Processing ID: $id, DLP: $dlp, Machine ID: $mach_id, Status: $status"

    # Skip if mach_id is empty
    if [[ -z "$mach_id" ]]; then
        continue
    fi

    uniqueMachIDs[$mach_id]=1


#    echo "Current mach_id: $mach_id"

    # Skip if status is "verified"
#    if [[ "$status" == "verified" ]]; then
#        continue
#    fi

    # If the current DLP is higher than the stored one or if mach_id doesn't exist in maxDLPs array
    if [[ -z ${maxDLPs[$mach_id]} || $(bc <<< "$dlp > ${maxDLPs[$mach_id]}") -eq 1 ]]; then
        maxDLPs[$mach_id]=$dlp
        maxIDsWithMaxDLPs[$mach_id]=$id
    fi
done

for mach_id in "${!uniqueMachIDs[@]}"; do
    echo "$mach_id"
done >> mach_id_list.txt

# Save maxIDsWithMaxDLPs to a file
{
    for mach_id in "${!maxIDsWithMaxDLPs[@]}"; do
        echo "$mach_id: ${maxIDsWithMaxDLPs[$mach_id]} DLP: ${maxDLPs[$mach_id]}"

    done
} >> maxIDsWithMaxDLPs.txt
#---------------------------------de Bugging

#*********************** create the instances
# Now, we only need IDs. Let's move them to the Offers array.
Offers=("${maxIDsWithMaxDLPs[@]}")
echo "$(date +%s): Error logs for machine_id. Tested  ${#Offers[@]} instances" > Error_testresults.log
echo "$(date +%s): Pass logs for machine_id. Tested  ${#Offers[@]} instances" > Pass_testresults.log
echo "$(date +%s): There are ${#Offers[@]} remaning offers to verify starting"
echo "$(date +%s) $Offers" > Offers.log

# Lock file base directory
lock_dir="/tmp/machine_tester_locks"
rm "$lock_dir"/lock*
mkdir -p "$lock_dir"
shopt -s nocasematch



while (( ${#active_instance_id[@]} < 20 && ${#Offers[@]} > 0 )) || (( ${#active_instance_id[@]} > 0 )); do
	echo "There are ${#Offers[@]} remaning offers to verify starting"
	declare -A machine_ids=()
	declare -A public_ipaddrs=()

	while (( ${#active_instance_id[@]} < 20 && ${#Offers[@]} > 0 )); do
       		next_offer="${Offers[0]}"  # Get the first offer
        	Offers=("${Offers[@]:1}")  # Remove the first offer from the Offers array
		if [ -z "$next_offer" ]; then
		    echo "No next offer available, exiting."
		    exit 1
		else 
		    echo "Next Offer: $next_offer"
		fi
                output=$(./vast create instance "$next_offer"  --image  jjziets/vasttest:latest  --ssh --direct --env '-e TZ=PDT -e XNAME=XX4 -p 5000:5000' --disk 20 --onstart-cmd 'python3 remote.py')
	    	echo "Output of create instance: $output"

	    # Check if the output starts with "Started. "
	    if [[ $output == Started.* ]]; then
	        # Strip the non-JSON part (i.e., "Started. ") from the output
	        json_output="${output#Started. }"
	        # Convert single quotes to double quotes and uppercase True to lowercase true
			json_output=$(echo "$json_output" | sed 's/'\''/"/g' | sed 's/True/true/g')

	        # Check if the operation was a success using jq
	        success=$(echo "$json_output" | jq -r '.success')

	        if [[ "$success" == "true" ]]; then
	            # If the operation was a success, extract the new_contract number using jq
	            new_contract=$(echo "$json_output" | jq -r '.new_contract')
	            # Append the extracted number to the contract array
	            active_instance_id+=("$new_contract")
	     	    CreateTime["$new_contract"]=$(date +%s)
	        fi
	    else
        	# Handle non "Started." outputs here, if needed
        	echo "Skipping non 'Started.' output: $output"
    	   fi
	done

	#*********************** start the testing 
	#update_machine_id_and_ipaddr  ## update the machine_id and the ip address
    to_remove=()  # Declare this before your loop starts
	for i in "${!active_instance_id[@]}"; do
 	    current_time=$(date +%s)
	    instance_id="${active_instance_id[$i]}"
	    actual_status=$(get_actual_status "$instance_id")
	    echo "$instance_id $actual_status"
	    if [ "$actual_status" == "running" ]; then
	        # Check if the instance is already in the start_times array
	        if [ -z "${start_times[$instance_id]}" ]; then
	          start_times[$instance_id]=$(date +%s)  # Store the start time for the instance
	        fi
	        # Calculate the running time for the instance
	        start_time="${start_times[$instance_id]}" #get the start time of this instance.
		if [ -z "${public_ipaddrs[$instance_id]}" ]; then
    		# If not, update the associative arrays
			echo "Public IP for instance $instance_id is empty. Updating"
	    		update_machine_id_and_ipaddr
	  	fi
		public_ip=${public_ipaddrs[$instance_id]}
		# Check if public_ip is empty
		if [ -z "$public_ip" ]; then
	    		echo "Public IP for instance $instance_id is empty. Skipping..."
		    	continue
		fi
		# Check if the machine_id is in the associative array
		if [ -z "${machine_ids[$instance_id]}" ]; then
	 	# If not, update the associative arrays
			echo "machine_id for instance $instance_id is empty. updating"
	 	   	update_machine_id_and_ipaddr
		fi
		machine_id=${machine_ids[$instance_id]}
		# Check if machine_id is empty
		if [ -z "$machine_id" ]; then
	    		echo "machine_id for instance $instance_id is empty. Skipping..."
	    		continue
		fi
	        public_port=$(python3 get_port_from_instance_id.py  "$instance_id")
	        exit_code=$?
	        if [ -z "$public_port" ]; then
	                echo "public_port for instance $instance_id is empty. Skipping..."
	        	continue
	        fi
                running_time=$(($(date +%s) - $start_time)) # get the runtime of  instanc
		if [ $exit_code -eq 2 ]; then
	            echo "$machine_id:$instance_id No Direct Ports found get_status_msg = running"  >> Error_testresults.log

	            ./vast destroy instance "$instance_id" #destroy the instance
	            #active_instance_id[$i]='0'
		    to_remove+=("$instance_id")
		    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
	        elif [ $exit_code -eq 0 ]; then
			required_time=15 #Startup time before running the script 
#			echo "required_time: $required_time   running_time: $running_time"
			remaining_time=$(($required_time - $running_time))
                        # Lock file for this script
			master_lock_file="$lock_dir/master_lock"
                        ./machinetester.sh "$public_ip" "$public_port" "$instance_id" "$machine_id" "$remaining_time" --debugging &
	                echo "$instance_id: starting machinetester $public_ip $public_port $instance_id $machine_id $remaining_time"
                        echo "$instance_id $machine_id $public_ip $public_port started" >> machinetester.txt
			to_remove+=("$instance_id")
			#active_instance_id[$i]='0'  # Mark this Instance for removal
			echo "Mark this Instance $instance_id for removal"
	                continue  # We've modified the array in the loop, so we break and start the loop anew
		#check if it has been waiting for more than 15min or if the instance has been running for 1m without any net response
	        elif (( $(date +%s) - ${CreateTime[$instance_id]:-0} > 2000 )) || (( $running_time > 60 )); then
		    echo "$machine_id:$instance_id Time exceeded get_status_msg $instance_id" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
	            to_remove+=("$instance_id")
	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
	        fi
	        elif [ "$actual_status" == "loading" ]; then
		#echo "Debug: CreateTime[$instance_id] = ${CreateTime[$instance_id]}"
	         #check if it has been waiting for more than 15min
		if (( $(date +%s) - ${CreateTime[$instance_id]:-0} > 2000 )); then 
	            echo "$machine_id:$instance_id Time exceeded get_status_msg = loading" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
		    to_remove+=("$instance_id")
	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
	        fi
	        #Status: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed
	        status_msg=$(get_status_msg "$instance_id")
	        if [[ $status_msg == "Error"* ]]; then
	            echo "$machine_id:$instance_id $instance_id  $status_msg" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
		    to_remove+=("$instance_id")
	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
	        fi
	        if [[ $status_msg == "Unable to find image"* ]]; then
	            echo "$machine_id:$instance_id $status_msg" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
		    to_remove+=("$instance_id")
	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
	        fi
		if [[ $status_msg == "Cannot connect to the Docker daemon"* ]]; then
	            echo "$machine_id:$instance_id  $status_msg" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
                    to_remove+=("$instance_id")
	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
	        fi
	    elif [ "$actual_status" == "created" ]; then
        #Status: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed
	        status_msg=$(get_status_msg "$instance_id")
	        if [[ $status_msg == "Error"* ]]; then
	            echo "$machine_id:$instance_id  $status_msg" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
		    to_remove+=("$instance_id")
	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
       		 elif (( $(date +%s) - ${CreateTime[$instance_id]} > 2000 )); then #check if it has been waiting for more than 10min
        	    echo "$machine_id:$instance_id Time exceeded get_status_msg $instance_id" >> Error_testresults.log
           	    ./vast destroy instance "$instance_id" #destroy the instance
		    to_remove+=("$instance_id")
 	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
 	           continue  # We've modified the array in the loop, so we break and start the loop anew
 	       fi
 	   elif [ "$actual_status" == "offline" ]; then
	            echo "$machine_id:$instance_id  went offline" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
		    to_remove+=("$instance_id")
	            #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
	    elif [ "$actual_status" == "exited" ]; then
	            echo "$machine_id:$instance_id  instance exited" >> Error_testresults.log
	            ./vast destroy instance "$instance_id" #destroy the instance
	            to_remove+=("$instance_id")
		    #active_instance_id[$i]='0'  # Mark this Instance for removal
                    echo "Mark this Instance $instance_id for removal"
	            continue  # We've modified the array in the loop, so we break and start the loop anew
            elif [ "$actual_status" == "unknown" ]; then
		if [ "$(search_instance "$instance_id")" == "false" ]; then
			echo "$machine_id:$instance_id Instance with ID: $instance_id not found."
			#echo "$machine_id:$instance_id  instance unknown not found" >> Error_testresults.log
                       ./vast destroy instance "$instance_id" #destroy the instance
                	to_remove+=("$instance_id")
			#active_instance_id[$i]='0'  # Mark this Instance for removal
			echo "Mark this Instance $instance_id for removal"
			continue # We've modified the array in the loop, so we break and start the loop anew
		else
			 echo "Instance with ID: $instance_id was found."
		fi
	    fi
	  done

    # Now we remove all marked elements

	for remove_id in "${to_remove[@]}"; do
    	active_instance_id=(${active_instance_id[@]/$remove_id/})  # Remove the ID from the array
	done


	done #Outer offer while

echo "done with all instances and offers"



while (( $(pgrep -fc machinetester.sh) > 0 ))
do
echo "Number of machinetester.sh processes still running: $(pgrep -fc machinetester.sh)"
sleep 10
done


./destroy_all_instances.sh "$1"


# List of files to convert
files=("Pass_testresults.log")

for file in "${files[@]}"; do
    # Checking if the file exists
    if [ ! -f "$file" ]
    then
        echo "File $file does not exist."
        continue
    fi

    # Reading the file and replacing new lines with commas
    sed ':a;N;$!ba;s/\n/,/g' "$file" > "${file%.*}_comma.log"
done

# Check if the machine_id is present in Pass_testresults.log
if grep -q "$machine_id" "Pass_testresults.log"; then
    cat "Pass_testresults.log"
else
    cat "Error_testresults.log"
fi

echo "Exit: done testing"
