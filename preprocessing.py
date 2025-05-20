import os
import SimpleITK as sitk


bids_root = "/OrganizedData" 

output_root = "sampled7T"
os.makedirs(output_root, exist_ok=True)

subject_ids = [f"sub-{str(i).zfill(2)}" for i in range(1, 7)]  

for sub_id in subject_ids:
    anat_dir = os.path.join(bids_root, sub_id, "ses-7T", "anat")
    
    if not os.path.isdir(anat_dir):
        print(f"Anat directory not found for {sub_id} in ses-7T session.")
        continue

    output_anat_dir = os.path.join(output_root, sub_id, "ses-7T", "anat")
    os.makedirs(output_anat_dir, exist_ok=True)

    # Process each NIfTI file in the anat directory
    for file_name in os.listdir(anat_dir):
        if file_name.endswith(".nii") or file_name.endswith(".nii.gz"):
            input_path = os.path.join(anat_dir, file_name)
            output_path = os.path.join(output_anat_dir, file_name)

            image = sitk.ReadImage(input_path)

            # spacing and size
            original_spacing = image.GetSpacing()
            original_size = image.GetSize()

            # upsampling factor
            upsample_factor = 2.0

            # Calculate new spacing and size
            new_spacing = [s / upsample_factor for s in original_spacing]
            new_size = [int(sz * upsample_factor) for sz in original_size]

            # Set up the resampler
            resampler = sitk.ResampleImageFilter()
            resampler.SetInterpolator(sitk.sitkBSpline)
            resampler.SetOutputSpacing(new_spacing)
            resampler.SetSize(new_size)
            resampler.SetOutputDirection(image.GetDirection())
            resampler.SetOutputOrigin(image.GetOrigin())

            # Perform resampling
            upsampled_image = resampler.Execute(image)

            # Save the upsampled image
            sitk.WriteImage(upsampled_image, output_path)
            print(f"Upsampled image saved to '{output_path}'.")