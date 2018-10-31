#!/bin/bash

# GIF SMASHER: A GIF file compressor that leverages ffmpeg and gifsicle to compress a video or GIF file to a GIF of a given size in bytes.

# Sites used as reference:
# http://blog.pkh.me/p/21-high-quality-gif-with-ffmpeg.html
# https://www.lcdf.org/gifsicle/man.html
# http://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
# http://stackoverflow.com/questions/4360647/finding-cubic-root-of-a-large-number

### PARSE INPUT

while [[ $# -gt 1 ]]; do
	key="$1"

	case $key in
	    -i|--input)
	    inputPath="$2"
	    shift
	    ;;
	    -t|--target)
	    targetMB="$2"
	    shift 
	    ;;
	    -I|--maxIter)
	    maxIterations="$2"
	    shift
	    ;;
	    -f|--fpsmin)
	    minFramerate="$2"
	    shift
	    ;;
	    -l|--lossymax)
	    maxLossy="$2"
	    shift
	    ;;
	    -c|--colormin)
	    minColors="$2"
	    shift
	    ;;
	    -s|--scalemin)
	    minScale="$2"
	    shift
		;;
	    -F|--fpswt)
	    fWeight="$2"
	    shift
		;;
	    -L|--lossywt)
	    lWeight="$2"
	    shift
		;;
	    -C|--colorwt)
	    cWeight="$2"
	    shift
		;;
	    -S|--scalewt)
	    sWeight="$2"
	    shift
		;;
	    *)
	            # unrecognized option
	    ;;
	esac
	shift # past argument or value
done


### PATH INITIALIZATION

ffmpeg=/jobs/transfer/2d_Tools/SamLloyd_Scripts/Applications_Server/__binaries/ffmpeg/ffmpeg
ffprobe=/jobs/transfer/2d_Tools/SamLloyd_Scripts/Applications_Server/__binaries/ffmpeg/ffprobe
gifsicle=/jobs/transfer/2d_Tools/SamLloyd_Scripts/Applications_Server/__binaries/gifsicle_lossy-mod
ffOutPath=/tmp/ffgif.gif
gsOutPath=/tmp/gsgif.gif
palettePath=/tmp/gifpalette.png


### SUPPORT FUNCTIONS

# Round function for post-increment value evaluation
# Input cannot have decimal value of .001 or less
round_up() { 
	echo $1 | awk '{print int($1+0.999)}'
}

round_down() { 
	echo $1 | awk '{print int($1)}'
}

absolute() {
	value=$1
	if [ "$value" -lt 0 ]; then
        return $(( $value * -1 ))
	else
		return $value
	fi
}

calc_to_2() {
	echo "scale=2; ($1) / 1" | bc -l
}

calc_to_int() {
	echo "scale=0; ($1) / 1" | bc -l
}


### VARIABLE INITIALIZATION

targetMode=approx

## shared variables

if [ -z "$inputPath" ]; then echo "Input file not specified. Exiting";      exit 1; fi
if [ -z "$targetMB" ]; then echo "Target filesize not specified. Exiting"; 	exit 1; fi

targetBytes=$(calc_to_int "$targetMB * 1000000" )
targetReached=false

# Set output path based on input path
outputPath="$(dirname "$inputPath")"/"$(basename -s ".mov" "$inputPath")" #.# File other than mov doesn't have its extension removed
if [[ -e "$outputPath".gif ]]; then
	i=1; while [[ -e "$outputPath($i)".gif ]]; do i=$(($i+1)); done
	outputPath="$outputPath($i)"
fi
outputPath="$outputPath".gif


## ffmpeg variables

rtValue=1 #-# Valid values are 0 or 1. Boolean for transparency in palette.
ditherValue=bayer:bayer_scale=2 #-# Valid values are none,floyd_steinberg,sierra2,sierra2_4a,bayer(w/:bayer_scale= option)
statsMode=full #-# Valid values are full,diff. Affects whether palette derived from all pixels or just ones that change.


## gifsicle variables

# IN THRESHOLD MODE
# Weights cannot be less than zero.  0 = invariable, 1 = even split across iterations.
# If a weight is <1 then min/max for that variable will never be reached.
# If a weight is >1 then min/max for that variable will be reached prior to the final iteration.

# IN APPROX MODE
# How variable weight changes with target weight, based on tests:
# FPS = SIZE
# LOSSINESS = (1/3)*SIZE^(-1/4)
# COLOR = SIZE^(1/2)
# SCALE = SIZE^2
if [ -z $fWeight ]; 		then fWeight=1; fi # Weight on framerate
if [ -z $lWeight ]; 		then lWeight=1; fi # Weight on lossiness
if [ -z $sWeight ]; 		then sWeight=1; fi # Weight on resolution scaling
if [ -z $cWeight ]; 		then cWeight=1; fi # Weight on color quantity
														
if [ -z $maxIterations ]; 	then maxIterations=6; fi #-# Zero and all positive ints are valid
														
if [ -z $minFramerate ]; 	then minFramerate=0.5; fi 	# FPS
if [ -z $maxLossy ];     	then maxLossy=200; fi 		# Arbitrary units
if [ -z $minScale ];    	then minScale=0.1; fi		# 1 = 100%
if [ -z $minColors ];    	then minColors=4; fi 		# Number of colors used
# Variables immediately below not relevant in iterations where ffmpeg involved
resizeMethod=lanczos3 #-# Valid values are sample,mix,catrom,mitchell,lanczos2,lanczos3
colorMethod=diversity #-# Valid values are diversity,blend-diversity,median-cut

# Initial values for gifsicle; best-quality settings
#initFramerate=10
initFramerate=$(calc_to_2 "$($ffprobe -select_streams v -show_streams "$inputPath" 2>/dev/null | grep avg_frame_rate | sed -e 's/avg_frame_rate=//')") #-# All positive values up to 100 are valid
initLossy=0 #-# Valid values are 0-200 (int)
initScale=1 #-# All positive values are valid
initColors=256 #-# Valid values are 4-256 (int)

# Variables modified with each iteration, initialized here
iteration=0
fBreadth=$(calc_to_2 "$initFramerate - $minFramerate")
lBreadth=$(calc_to_2 "$maxLossy - $initLossy")
sBreadth=$(calc_to_2 "$initScale - $minScale")
cBreadth=$(calc_to_2 "$initColors - $minColors")
framerateValue=$initFramerate
lossyValue=$(($maxLossy < $initLossy ? $maxLossy : $initLossy))
scaleValue=$initScale
colorsValue=$initColors


#Relativize weights
weightSum=$(calc_to_2 "($fWeight + $lWeight + $sWeight + $cWeight)")
weightSum="2.00"
fWeight=$(calc_to_2 "$fWeight/$weightSum")
lWeight=$(calc_to_2 "$lWeight/$weightSum")
sWeight=$(calc_to_2 "$sWeight/$weightSum")
cWeight=$(calc_to_2 "$cWeight/$weightSum")

echo "F"$fWeight
echo "L"$lWeight
echo "S"$sWeight
echo "C"$cWeight

### MAIN FUNCTION - APPROXIMATION MODE
if [ $targetMode = approx ]; then
	while [ $targetReached = false ]; do
		
		(( iteration = iteration + 1 ))
		
		echo -e "\nIteration: "$iteration
		echo "Framerate: "$framerateValue
		echo "Lossiness: "$lossyValue
		echo "Scale: "$scaleValue
		echo "Colors: "$colorsValue

		## FFMPEG
			
			## Generate initial GIF with highest-quality ffmpeg settings. If small enough, copy to output path.
			# Generate palette
			"$ffmpeg" -loglevel error -y -i "$inputPath" -vf palettegen=max_colors=$colorsValue:reserve_transparent=$rtValue:stats_mode=$statsMode /tmp/gifpalette.png
			# Generate GIF file
			"$ffmpeg" -loglevel error -y -i "$inputPath" -i "$palettePath" -r $framerateValue -lavfi paletteuse=dither=$ditherValue "$ffOutPath"
			# Check file size
			ffBytes=$(stat -f "%z" "$ffOutPath")
			echo "FFMPEG GIF bytes: "$ffBytes

		
		"$gifsicle" --no-warnings "$ffOutPath" -O3 --lossy=$lossyValue --colors $colorsValue --color-method $colorMethod --scale $scaleValue --resize-method $resizeMethod -o "$gsOutPath" 

		gsBytes=$(stat -f "%z" "$gsOutPath")
		echo "GIFSICLE GIF bytes: "$gsBytes
	
		#involatility=0.1 # The higher this number, the less volatile the adjustments
				
		# Alter weights based on byte discrepancy. (Algorithm was created through trial and error, not any mathematical principle)
		#globalWeight=$(echo "define inversethroot(x) { return e(l(x)/(1/x)) }; scale=4; inversethroot($targetBytes / $gsBytes)" | bc -l)
		globalWeight=$(calc_to_2 "$targetBytes / $gsBytes")
		
		echo "Global weight on next iteration: "$globalWeight
	
		if [ $iteration -ge $maxIterations ] || [ $(calc_to_int "$globalWeight * 100") -eq 100 ]; then
			cp "$gsOutPath" "$outputPath"
			#rm "$ffOutPath" "$palettePath" "$gsOutPath"
			echo "GIF created at $outputPath ($iteration iteration(s) total)."
			targetReached=true
		else
			
			
			# How size changes with isolated variables, based on tests:
			# FPS ∝ SIZE
			# LOSSINESS ∝ (1/3)*SIZE^(-1/4)
			# COLOR ∝ SIZE^(1/2)
			# SCALE ∝ SIZE^2
			
			# in bc, x^y must be written as e(y*l(x)) if y is non-integer.
				
			# Framerate
			#if [ $(calc_to_int "$globalWeight * 100") -gt 100 ]; then
				framerateValue=$(calc_to_2 "$framerateValue - $framerateValue * $fWeight * (1 - $globalWeight)")
				if [ $(calc_to_int "$framerateValue * 100") -le $(calc_to_int "$minFramerate * 100") ]; then
					framerateValue=$minFramerate
				elif [ $(calc_to_int "$framerateValue * 100") -ge $(calc_to_int "$initFramerate * 100") ]; then
					framerateValue=$initFramerate
				fi
				#fi
			#echo "FDONE"
			
			# Lossiness
			if [ $(calc_to_int "$lWeight * 100") -gt 0 ]; then
				lossyValue=$(round_down $(calc_to_2 "$lossyValue + 18 * $lWeight * (1 - (($globalWeight)^4))"))
				if [ $lossyValue -ge $maxLossy ]; then
					lossyValue=$maxLossy
				elif [ $lossyValue -le $initLossy ]; then
					lossyValue=$initLossy
				fi
			fi
			#echo "LDONE"
		
			# Scale
			if [ $(calc_to_int "$sWeight * 100") -gt 0 ]; then
				scaleValue=$(calc_to_2 "$scaleValue - $scaleValue * $sWeight * (1 - (sqrt($globalWeight)))")
				if [ $(calc_to_int "$scaleValue * 100") -le $(calc_to_int "$minScale * 100") ]; then
					scaleValue=$minScale
				elif [ $(calc_to_int "$scaleValue * 100") -ge $(calc_to_int "$initScale * 100") ]; then
					scaleValue=$initScale
				fi
			fi
			#echo "SDONE"
		
			# Colors
			if [ $(calc_to_int "$cWeight * 100") -ge 0 ]; then
				colorsValue=$(round_up $(calc_to_2 "$colorsValue - $colorsValue * $cWeight * (1 - ($globalWeight)^2)"))
				if [ $colorsValue -le $minColors ]; then
					colorsValue=$minColors
				elif [ $colorsValue -ge $initColors ]; then
					colorsValue=$initColors
				fi
			fi
			#echo "CDONE"
		fi
	done
fi

### MAIN FUNCTION - THRESHOLD MODE
if [ $targetMode = threshold ]; then 
	# Iterate optimization until size achieved or constraints met.
	while [ $targetReached = false ] && [ $iteration -le $maxIterations ]; do
	
		echo -e "\nIteration: "$(( iteration + 1 ))
		echo "Framerate: "$framerateValue
		echo "Lossiness: "$lossyValue
		echo "Scale: "$scaleValue
		echo "Colors: "$colorsValue
	
		## FFMPEG
		# Only need ffmpeg to convert to gif from video and to do FPS alterations.
		if [[ $framerateValue != $initFramerate ]] || ( [[ $iteration == 0 ]] && [[ "$inputPath" != *.gif ]] ); then
	
			## Generate initial GIF with highest-quality ffmpeg settings. If small enough, copy to output path.
			# Generate palette
			"$ffmpeg" -loglevel error -y -i "$inputPath" -vf palettegen=max_colors=$colorsValue:reserve_transparent=$rtValue:stats_mode=$statsMode /tmp/gifpalette.png
			# Generate GIF file
			"$ffmpeg" -loglevel error -y -i "$inputPath" -i "$palettePath" -r $framerateValue -lavfi paletteuse=dither=$ditherValue "$ffOutPath"
			# Check file size
			ffBytes=$(stat -f "%z" "$ffOutPath")
			echo "FFMPEG GIF bytes: "$ffBytes
			# Copy and finish if already under target
			if [ $ffBytes -le $targetBytes ]; then
				cp "$ffOutPath" "$outputPath"
				#rm "$ffOutPath" "$palettePath" "$gsOutPath"
				echo "GIF created at $outputPath. ($iteration.5 iterations total)."
				targetReached=true
			#elif [ $maxIterations -eq 0 ]; then
			#	mv "$ffOutPath" "$outputPath"
			#	#rm "$palettePath"
			#	echo "GIF created at $outputPath. (Exceeds target size but gifsicle iterations were set to zero.)"
			#	targetReached=false
			fi
		fi
	
		
		## GIFSICLE

	
		if [ $targetReached = false ]; then
		
			(( iteration = iteration + 1 ))
		
			"$gifsicle" --no-warnings "$ffOutPath" -O3 --lossy=$lossyValue --colors $colorsValue --color-method $colorMethod --scale $scaleValue --resize-method $resizeMethod -o "$gsOutPath" 
	
			gsBytes=$(stat -f "%z" "$gsOutPath")
			echo "GIFSICLE GIF bytes: "$gsBytes
		
			if [ $gsBytes -le $targetBytes ]; then
				cp "$gsOutPath" "$outputPath"
				#rm "$ffOutPath" "$palettePath" "$gsOutPath"
				echo "GIF created at $outputPath ($iteration iteration(s) total)."
				targetReached=true
			else
				iterMult="($iteration / $maxIterations)"
			
				# Framerate
				if [ $(calc_to_int "$fWeight * 100") -gt 0 ]; then
					weightedFramerate=$(calc_to_2 "$initFramerate - ($fWeight * $fBreadth * $iterMult)")
					if [ $(calc_to_int "$weightedFramerate * 100") -lt $(calc_to_int "$minFramerate * 100") ]; then
						framerateValue=$minFramerate
					else
						framerateValue=$weightedFramerate
					fi
				fi
			
				# Lossiness
				if [ $(calc_to_int "$lWeight * 100") -gt 0 ]; then
					weightedLossy=$(round_up $(calc_to_2 "$initLossy + ($lWeight * $lBreadth * $iterMult)"))
					if [ $weightedLossy -gt $maxLossy ]; then
						lossyValue=$maxLossy
					else
						lossyValue=$weightedLossy
					fi
				fi
			
				# Scale
				if [ $(calc_to_int "$sWeight * 100") -gt 0 ]; then
					weightedScale=$(calc_to_2 "$initScale - ($sWeight * $sBreadth * $iterMult)")
					if [ $(calc_to_int "$weightedScale * 100") -lt $(calc_to_int "$minScale * 100") ]; then
						scaleValue=$minScale
					else
						scaleValue=$weightedScale
					fi
				fi
			
				# Colors
				if [ $(calc_to_int "$cWeight * 100") -gt 0 ]; then
					weightedColors=$(round_up $(calc_to_2 "$initColors - ($cWeight * $cBreadth * $iterMult)"))
					if [ $weightedColors -lt $minColors ]; then
						colorsValue=$minColors
					else
						colorsValue=$weightedColors
					fi
				fi

			fi
				
		fi
	done
fi


if [ $targetReached = false ]; then
	chmod -R 777 "$gsOutPath"
	cp "$gsOutPath" "$outputPath"
	#rm "$gsOutPath" "$ffOutPath" "$palettePath"
	echo "GIF created at $outputPath ($maxIterations iteration(s) total). (Target size was too small for constraints.)"
fi

exit 0



# Framerate adjustment in gifsicle <unused reason="Creates artifacts when source file's palette contains transparency">
#
#inputFrameCount=$($ffprobe -select_streams v -show_streams "$inputPath" 2>/dev/null | grep nb_frames | sed -e 's/nb_frames=//')
#
#	
#	keepInterval=$(echo "scale=2; $framerateValue / $initFramerate" | bc )
#	frameRemovalString="--delete"
#	keepThreshold=0
#	i=0
#	
#	while [ $i -lt $inputFrameCount ]; do
#		
#		keepThreshold=$(echo "scale=2; $keepThreshold + $keepInterval" | bc )
#		keepThresholdInt=$(echo $keepThreshold | awk '{print int($1)}')
#		
#		if [ $keepThresholdInt -lt 1 ]; then
#			frameRemovalString="$frameRemovalString #$i"
#		else
#			keepThreshold=$(echo "scale=2; $keepThreshold - 1" | bc ) 
#		fi
#		
#		i=$((i+1))
#	done
#fi
#delayValue=$(echo "scale=0; 100 / $framerateValue" | bc)
# </unused>