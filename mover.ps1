function look-Files($lookupPath, $extension, $filter){
	$files = Get-ChildItem -Path $lookupPath -Recurse -Include $extension | ? { $_.FullName -inotmatch $filter }
	return $files
}

function write-Debug($filename, $source, $dest, $batch, $error, $extension){
	# Should retrieve the fileobject in question
	# A list of files in source and dest
	# The current batch
	$sourcefiles = look-Files $source "*$extension" "original"
	$destfiles = look-Files $dest "*$extension" "original"
	$out = "
	Error Type: $error
	File name: $filename
	Files at source:
	$sourcefiles
	
	Files at destination:
	$destfiles
	
	Current batch:
	$batch
	"
	$path = $filename + ".txt"

	$out | Out-File -FilePath $path
	exit
}

# A function to test whether the file is actually locked by the OS
function Test-FileLock {
	param ([parameter(Mandatory=$true)][string]$Path)
	
	if ((Test-Path -Path $Path) -eq $false){
		return $false
	} else {
		$oFile = New-Object System.IO.FileInfo $Path
		try {
			$oStream = $oFile.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
			if ($oStream){
				$oStream.Close()
			}
			return $true
		} catch {
		# file is locked by a process.
			return $false
		}
	}
}

# This is teh code executed by the spawned job
$copy_functions = {
	Param(	$file, # Full file name of the file to be copied
			$destination, #Where to copy
			$delete, # Should the original be deleted?
			$src) # the source path to locate the original folder
	
	# Copies an Item and checks by file hash
	function copy-and-check($file, $dest){
		# Copy the item
		# TODO: make temp file for check and then rename
		$temp_name = $dest+"\"+$file.Name+".tmp"
		Copy-Item "$file" -Destination "$temp_name" -Force
		
		# Checking the hashes
		if( (Get-FileHash $file.FullName -Algorithm "md5").hash -eq (Get-FileHash $temp_name -Algorithm "md5").hash){
			Rename-Item -Path $temp_name -NewName $file.Name
			return $TRUE
		} else {
			# No rename in case of failure
			# Delete failed file
			Remove-Item $temp_name
			return $FALSE
		}
		
	}

# Do the work here

	if (copy-and-check $file $destination){
		if ($delete -eq "y"){
			if ((Test-Path -path $file) -eq $TRUE){
				Remove-Item $file
			}
			# Code 1: File was successfully moved
			Write-Output "1"
		} else {
			#Move item instead? -> Will be faster?
			if(copy-and-check $file ($src+"\original")){
				Remove-Item $file
				# Code 1: File was successfully moved
				Write-Output "1"
			} else {
				# Code 2: There was a problem while backing up the file to original
				# TODO: This should trigger a retry!
				# Dest file is already removed by copy and check
				# Staring file is kept
				# Remove from batch!
				Write-Output "2"
			}
		}
	} else {
		# Code 3: The initial copying from scr to dest failed.
		Write-Output "3"
	}
}


# get inputs
$ext = Read-Host -Prompt 'File extension'

if (($ext.StartsWith(".")) -eq $FALSE){
	$ext = ".$ext"
}

$src = Read-Host -Prompt 'Path to image stacks'
# Check existence
if(!(Test-Path -Path $src )){
	Write-Host "$src does not exist."
	exit
}
Write-Host "Reading stacks from $src"

$destination = Read-Host -Prompt 'Destination for image stacks'
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
$debug = Read-Host -Prompt 'Debug mode? (y/n)'


# Array list to hold the currently processed files
$batch = @()
# Starting time of the sript
$startTime = Get-Date
# Last timing tick
$lastTick = Get-Date

while ($TRUE) {

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
				Write-Host "A checksum error occured while backing up "$job.Name
				# Remove this file from the batch
				$batch = $batch | where {$_ -ne $job.Name}
				Write-Host "Try later again."
				if ($debug -eq "y"){
					write-Debug $job.Name $src $destination $batch $out $ext
				}
			} elseif($out -eq 3){
				Write-Host "Copying of"$job.Name" failed. Retry later again."
				# Remove this file from the batch
				$batch = $batch | where {$_ -ne $job.Name}
				if ($debug -eq "y"){
					write-Debug $job.Name $src $destination $batch $out $ext
				}
				
			} else {
				Write-Host "An unknown error has occured. Stopping execution."
				Write-Debug $job.Name $src $destination $batch $out $ext
				Write-Host "Wrote debug information."
				exit
			}
			# Remove the jobs that are done
			$job | Remove-Job
		}
	}
	
	# Check if new jobs have to be started
	$num_running = $running.count
	if ($num_running -lt $limit){
		# Check the files to be done, this gives full file objects
		$list_result = look-Files $src "*$ext" "original"

		if ($list_result.count -ne 0){
											
			
			# Clean the filelist from the ones that are contained in the batch
			$list_no_batch = $list_result | where { $batch -notcontains $_.FullName }
			# Remove files newer than 1 minute			
			$fiList = $list_no_batch | Where {$_.LastWriteTime -lt (Get-Date).AddMinutes(-1)}

			# Start jobs			
			for ($i=0; $i -lt ($limit-$num_running); $i++){
				# If there is no files left, dont do anything
				if ($fiList.count -ne 0){					
					# Gets the first object from the clean file list
					$current_file = $fiList[0]
					if ( (Test-FileLock $current_file) -eq $true){
						Write-Host "Start copying "$current_file.FullName
						$jo = Start-Job -name $current_file.FullName -ScriptBlock $copy_functions -ArgumentList $current_file,$destination,$delete,$src
						
						#Adds the current item to the batch
						$batch += $current_file.FullName
						# Removes the current item from the file list
						$fiList = $fiList | where { $batch -notcontains $_.FullName }
					} else {
						if ($debug -eq "y"){
							Write-Host $current_file" is locked."
						}
					}
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
	Start-sleep 1
}

# Todo:
# Sanity check inputs for type
# Keeping the files is 2x slower because it performs an additional copy-and-check -> move instead and compare to the dest file?
