function look-Files($lookupPath, $extension, $filter){
	$files = Get-ChildItem -Path $lookupPath -Recurse -Include $extension | ? { $_.FullName -inotmatch $filter }
	return $files
}

# This is teh code executed by the spawned job
$copy_functions = {
	Param(	$file,
			$destination,
			$delete,
			$src) # the source path to locate the original folder
	
	# Copies an Item and checks by file hash
	function copy-and-check($file, $dest){
		# Copy the item
		Copy-Item "$file" -Destination "$dest" -Force
		Start-Sleep 5
		# Checking the hashes
		if( (Get-FileHash $file.FullName -Algorithm "md5").hash -eq (Get-FileHash ($dest+"\"+$file.Name) -Algorithm "md5").hash){
			return $TRUE
		} else {
			return $FALSE
		}
	}

# Do the work here

	if (copy-and-check $file $destination){
		if ($delete -eq "y"){
			Remove-Item $file
			Write-Output "1"
		} else {
			#Move item instead? -> Will be faster?
			if(copy-and-check $file ($src+"\original")){
				Remove-Item $file
				Write-Output "1"
			} else {
				# This is severe, because the backup seems a problem
				Write-Output "2"
			}
		}
	} else {
		# This should trigger to copy the file to original
		Write-Output "3"
	}
}




# get inputs
$src = Read-Host -Prompt 'Path to MRC stacks'
# Check existence
if(!(Test-Path -Path $src )){
	Write-Host "$src does not exist."
	exit
}
Write-Host "Reading stacks from $src"

$destination = Read-Host -Prompt 'Destination for MRC stacks'
# Check existence
if(!(Test-Path -Path $destination )){
	Write-Host "$destination does not exist."
	exit
}
Write-Host "Moving stacks to $destination"

$limit = Read-Host -Prompt 'How many stacks should be processed in parallel?'
Write-Host "Moving $num stacks at once."

$delete = Read-Host -Prompt 'Delete original files after copying?(y/n)'
if ($delete -eq "y"){
	Write-Host "Original files will be deleted"
} elseif ($delete -eq "n"){
	Write-Host "Original files will be kept"
	$out = New-Item -ItemType directory -Path ($src+"\original")	
} else {
	Write-Host "Unrecognized option for this parameter. Original files will be kept."
	$delete = "n"
	# Create originals folder if not existing
	if(!(Test-Path -Path ($src+"\original") )){
		$out = New-Item -ItemType directory -Path ($src+"\original")
	}
}

# File size
$filesize = 0
# Run switch for the main while loop
$active = $TRUE
# Array list to hold the currently processed files
$batch = @()

$startTime = Get-Date

$lastTick = Get-Date


while ($active) {
	if ($filesize -eq 0) {
		# Here some start up routine, determine filesizes
		$init_list = look-Files $src "*.mrc" "original"
		# wait for the first 4 files to appear
		if ($init_list.count -ne 4){
			$test_files = $init_list[0..3].FullName
			while($true){
				if ( ((Get-Item $test_files[0]).length -eq (Get-Item $test_files[1]).length) -and ((Get-Item $test_files[0]).length -eq (Get-Item $test_files[2]).length) -and ((Get-Item $test_files[0]).length -eq (Get-Item $test_files[3]).length)){
					$filesize = (Get-Item $test_files[0]).length
					Write-Host "Successfully determined expected file size ($filesize bytes)."
					break
				} else {
					Write-Host "Waiting to determine expected filesize from first 4 files..."
					Start-Sleep 5
				}
			}
		}
	} else {
		# Start the actual moving here
		# look for jobs
		$running = Get-Job
		
		# look through them if there is completed ones
		foreach ($job in $running){
			if ($job.state -eq "Completed"){
				#$job | Select-Object -Property *
				# Job should return a number
				[int]$out = ($job | Receive-Job)
				# Check states here: 1 = ok; 2 = checksum second copy; 3 = checksum first copy
				if ($out -eq 1){
					Write-Host "Done copying "$job.Name
				} elseif ($out -eq 2){
					Write-Host "A checksum error occured while copying "$job.Name
					Write-Host "Kept the original file just in case."
				} elseif($out -eq 3){
					Write-Host "A checksum error occured while copying "$job.Name
					Write-Host "Kept the original file just in case."
				} else {
					Write-Host "An unknown error has occured. Stopping execution."
					$active = $FALSE
				}
				# Remove the jobs that are done
				$job | Remove-Job
			}
		}
		
		# Check if new jobs have to be started
		$num_running = $running.count
		if ($num_running -lt $limit){
			# Check the files to be done, this gives full file objects
			$list_result = look-Files $src "*.mrc" "original"

			if ($list_result.count -ne 0){
												
				
				# Clean the filelist from the ones that are contained in the batch
				$fiList = $list_result | where { $batch -notcontains $_.FullName }
				
				# Start jobs			
				for ($i=0; $i -lt ($limit-$num_running); $i++){
					# If there is no files left, dont do anything
					if ($fiList.count -ne 0){					
						# Gets the first object from the clean file list
						$current_file = $fiList[0]
						Write-Host "Start copying "$current_file.FullName
						$jo = Start-Job -name $current_file.FullName -ScriptBlock $copy_functions -ArgumentList $current_file,$destination,$delete,$src
						
						#Adds the current item to the batch
						$batch += $current_file.FullName
						# Removes the current item from the file list
						$fiList = $fiList | where { $batch -notcontains $_.FullName }
					}
				}
			}
			
			$timeSincelastTick = (New-TimeSpan -Start $lastTick -End (Get-Date)).TotalSeconds
			if ($timeSincelastTick -gt 30){
				# Status check
				Write-Host "-------------------------------------"
				Write-Host "Found "$list_result.count" new stacks."
				# Speed check
				[int]$runSpeed = $batch.count / (( ( (New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds ) /60 ) / 60)
				Write-Host "Running at "($runSpeed)" images per hour."
				Write-Host "-------------------------------------"
				# Set new tick
				$lastTick = Get-Date
			}
		}
	}
	Start-sleep 1
}

# Todo:
# Sanity check inputs for type
# Check if source and target dirs are actually there
# Keeping the files is 2x slower because it performs an additional copy-and-check -> move instead and compare to the dest file?
# Set window size by script
# Emercency triggers for checksum errors (exit codes 2 and 3) -> make backup folder