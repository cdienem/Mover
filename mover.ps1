
# get inputs
$src = Read-Host -Prompt 'Path to MRC stacks'
Write-Host "Reading stacks from '$src'."

$dst = Read-Host -Prompt 'Destination for MRC stacks'
Write-Host "Moving stacks to '$dst'."

$num = Read-Host -Prompt 'How many stacks should be processed in parallel?'
Write-Host "Moving '$num' stacks at once."

$delete = Read-Host -Prompt 'Delete original files after copying?(y/n)'
if ($delete -eq "y"){
	Write-Host "Original files will be deleted"
} elseif ($delete -eq "n"){
	Write-Host "Original files will be kept"
	$out = New-Item -ItemType directory -Path ($src+"\original")	
} else {
	Write-Host "Unrecognized option for this parameter. Original files will be kept."
	$delete = "n"
	$out = New-Item -ItemType directory -Path ($src+"\original")
}

# Error handling for New-Item???


$filesize = 0

function look-Files($lookupPath, $extension, $filter){
	$files = Get-ChildItem -Path $lookupPath -Recurse -Include $extension | ? { $_.FullName -inotmatch $filter }
	return $files
}

function copy-and-check($file, $dest){
	# Copy the item
	Copy-Item "$file" -Destination "$dest" -Force
	# Checking the hashes
	if( (Get-FileHash $file.FullName).hash -eq (Get-FileHash ($dest+"\"+$file.Name)).hash){
		return $TRUE
	} else {
		return $FALSE
	}
}



while ($TRUE) {
	# look for files
	$fiList = look-Files $src "*.mrc" "original"
	if ($filesize -eq 0) {
		# Here some start up routine, determine filesizes
		$test_files = $fiList[0..3].FullName
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
	} else {
		Write-Host "I like to move it move it..."
		$batch = $fiList[0..($num-1)]
		foreach ($f in $batch){
			if ((Get-Item $f).length -eq $filesize){
				Write-Host "Copying $f..."
				if (copy-and-check $f $dst){
					Write-Host "Done."
					if ($delete -eq "yes"){
						
					} else {
						if(copy-and-check $f ($src+"\original")){
							Remove-Item $f
						} else {
							Write-Host "There was a checksum error! Kept the file to be sure."
						}
					}
				} else {
					Write-Host "There was a checksum error! Kept the file to be sure."
				}
			}
		}
		# do filesize check
		
		# move file
		# do md5 check
		# delete or copy file
		
		break
	}
}













# first 4 files: wait until their size does not change and save this filesize as sanity check

# read files that have the right size
# take $batchsize first items

# remove from que
# move or copy these files
# keep a list of completed files
# go back to <1>
