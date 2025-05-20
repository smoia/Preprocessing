#!/usr/bin/env bash

# shellcheck source=../utils.sh
source $( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/utils.sh

displayhelp() {
echo "Required:"
echo "anat"
echo "Optional:"
echo "aref tmp"
exit ${1:-0}
}

# Check if there is input

if [[ ( $# -eq 0 ) ]]
	then
	displayhelp
fi

# Preparing the default values for variables
tmp=/tmp
debug=no
TEs="9.46 24.66 39.86"

### print input
printline=$( basename -- $0 )
echo "${printline}" "$@"
# Parsing required and optional variables with flags
# Also checking if a flag is the help request or the version
while [ ! -z "$1" ]
do
	case "$1" in
		-anat)		anat=$2;shift;;

		-TEs)		TEs="$2";shift;;
		-tmp)		tmp=$2;shift;;
		-debug)		debug=yes;;

		-h)			displayhelp;;
		-v)			version;exit 0;;
		*)			echo "Wrong flag: $1";displayhelp 1;;
	esac
	shift
done

# Check input
checkreqvar anat
checkoptvar TEs tmp debug

[[ ${debug} == "yes" ]] && set -x

### Remove nifti suffix
anat=$( removeniisfx ${anat} )



### Cath errors and exit on them
set -e
######################################
######### Script starts here #########
######################################

cwd=$(pwd)

# Parse anat filename and fix folder
[[ "$anat" =~ sub-([^_]+)_ses-([^_]+)?(_run-([^_]+))? ]] && \
  sub=${BASH_REMATCH[1]} && \
  ses=${BASH_REMATCH[2]} && \
  run=${BASH_REMATCH[4]:-}

workdir=$( dirname $( realpath ${anat} ) | sed -E 's|/sub-[^_]+/ses-[^_]+/anat/.*||')
adir=${workdir}/sub-${sub}/ses-${ses}/anat
aderivdir=${workdir}/derivatives/vessels/sub-${sub}/ses-${ses}/anat
rderivdir=${workdir}/derivatives/vessels/sub-${sub}/ses-${ses}/reg
anat=$( basename ${anat} )
anatprefix=sub-${sub}_ses-${ses}
anatsuffix=${anat#*_echo-?_}

tmp=${tmp}/sub-${sub}_ses-${ses}_vesselsbfc


cd ${adir} || exit 1

#Read and process input
if_missing_do mkdir ${tmp}
if_missing_do mkdir ${aderivdir} ${rderivdir}

anatfiles=()


for acqs in invRO normRO
do
	workanat=${anatprefix}_acq-${acqs}
	for echos in 1 2 3
	do
		workanatsuffix=echo-${echos}_${anatsuffix}
		# -n because run is set but maybe empty
		if [[ -n "${run}" ]]
		then
			for runs in 01 02
			do
				anatfiles+=("${workanat}_run-${runs}_${workanatsuffix}")
			done
		else
			anatfiles+=("${workanat}_${workanatsuffix}")
		fi
	done
done

# Crop and bias field correct anats
for anatfile in "${anatfiles[@]}"
do
	## 01.Crop 
	3dAutobox -input ${adir}/${anatfile}.nii.gz -prefix ${tmp}/${anatfile}_ab.nii.gz
	## 02. Bias Field Correction with ANTs
	# 02.1. Truncate (0.01) for Bias Correction
	echo "Performing BFC on ${anatfile}"
	ImageMath 3 ${tmp}/${anatfile}_trunc.nii.gz TruncateImageIntensity ${tmp}/${anatfile}_ab.nii.gz 0.02 0.98 256
	# 02.2. Bias Correction
	N4BiasFieldCorrection -d 3 -i ${tmp}/${anatfile}_trunc.nii.gz -o ${tmp}/${anatfile}_bfc.nii.gz
done

# Prepare echoes averaging and T2* mapping
anatfiles_echo=()

for acqs in invRO normRO
do
	workanat=${anatprefix}_acq-${acqs}
	if [[ -n "${run}" ]]
	then
		for runs in 01 02
		do
			anatfiles_echo+=("${workanat}_run-${run}")
		done
	else
		anatfiles_echo+=("${workanat}")
	fi
done

for i in "${!anatfiles_echo[@]}"
do
	anatfile=${anatfiles_echo[i]}
	
	# T2* mapping and optimal combination
	t2smap -d ${tmp}/${anatfile}_echo-?_${anatsuffix}_bfc --masktype none -e "${TEs}" --out-dir ${tmp}/TED
	fslmaths ${tmp}/TED/desc-optcom_bold.nii.gz ${tmp}/${anatfile}_optcom_${anatsuffix}.nii.gz -odt float
	fslmaths ${tmp}/TED/T2starmap.nii.gz ${tmp}/${anatfile}_t2star_${anatsuffix}.nii.gz -odt float

	# echo average
	# [ you can substitute this average step with your code if you prefer ]
	3dMean -prefix ${tmp}/${anatfile}_echoavg_${anatsuffix}.nii.gz ${tmp}/${anatfile}_echo-?_${anatsuffix}_bfc.nii.gz

	# sampling
	python resample.py ${tmp} ${anatfile} ${anatsuffix} 
 
	# realign to vesselref (first file in input)
	if (( i == 0 ))
	then
		if_missing_do copy ${tmp}/${anatfile}_echoavg_${anatsuffix} ${rderivdir}/sub-${sub}_ses-${ses}_vesselref_downsampled.nii.gz
		if_missing_do copy ${tmp}/${anatfile}_echoavg_upsampled_${anatsuffix} ${rderivdir}/sub-${sub}_ses-${ses}_vesselref.nii.gz
		if_missing_do copy ${tmp}/${anatfile}_echoavg_upsampled_${anatsuffix} ${aderivdir}/${anatfile}_echoavg_${anatsuffix}2vesselref.nii.gz
		if_missing_do copy ${tmp}/${anatfile}_optcom_upsampled_${anatsuffix} ${aderivdir}/${anatfile}_optcom_${anatsuffix}2vesselref.nii.gz
		if_missing_do copy ${tmp}/${anatfile}_t2star_upsampled_${anatsuffix} ${aderivdir}/${anatfile}_t2star_${anatsuffix}2vesselref.nii.gz
	else
		flirt -in ${tmp}/${anatfile}_echoavg_upsampled_${anatsuffix} -ref ${rderivdir}/sub-${sub}_ses-${ses}_vesselref.nii.gz -cost normcorr -searchcost normcorr -dof 6 \
		-omat ${rderivdir}/${anatfile}2vesselref_fsl.mat -o ${aderivdir}/${anatfile}_echoavg_${anatsuffix}2vesselref.nii.gz
		flirt -in ${tmp}/${anatfile}_optcom_upsampled_${anatsuffix} -ref ${rderivdir}/sub-${sub}_ses-${ses}_vesselref.nii.gz \
		-init ${rderivdir}/${anatfile}2vesselref_fsl.mat -applyxfm -o ${aderivdir}/${anatfile}_optcom_${anatsuffix}2vesselref.nii.gz
		flirt -in ${tmp}/${anatfile}_t2star_upsampled_${anatsuffix} -ref ${rderivdir}/sub-${sub}_ses-${ses}_vesselref.nii.gz \
		-init ${rderivdir}/${anatfile}2vesselref_fsl.mat -applyxfm -o ${aderivdir}/${anatfile}_t2star_${anatsuffix}2vesselref.nii.gz
	fi
done

# Average all echo averages, optcoms, and t2* maps
3dMean -prefix ${aderivdir}/00.${anatprefix}_${anatsuffix}_esavgd_preprocessed.nii.gz ${aderivdir}/${anatprefix}_*_echoavg_${anatsuffix}2vesselref.nii.gz
3dMean -prefix ${aderivdir}/00.${anatprefix}_${anatsuffix}_optcom_preprocessed.nii.gz ${aderivdir}/${anatprefix}_*_optcom_${anatsuffix}2vesselref.nii.gz
3dMean -prefix ${aderivdir}/00.${anatprefix}_${anatsuffix}_t2star_preprocessed.nii.gz ${aderivdir}/${anatprefix}_*_t2star_${anatsuffix}2vesselref.nii.gz

# Brain extraction
3dSkullStrip -input ${aderivdir}/00.${anatprefix}_${anatsuffix}_esavgd_preprocessed.nii.gz \
			 -prefix ${tmp}/anat_brain.nii.gz \
			 -orig_vol -overwrite
# Momentarily forcefully change header because SkullStrips plumbs the volume.
3dcalc -a ${aderivdir}/00.${anatprefix}_${anatsuffix}_esavgd_preprocessed.nii.gz -b ${tmp}/anat_brain.nii.gz -expr "a*step(b)" \
	   -prefix ${tmp}/anat_brain.nii.gz -overwrite
fslmaths ${tmp}/anat_brain.nii.gz -bin ${aderivdir}/00.${anatprefix}_${anatsuffix}_mask

cd ${cwd}

if [[ ${debug} == "yes" ]]; then set +x; else rm -rf ${tmp}; fi
