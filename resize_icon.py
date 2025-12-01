from PIL import Image

def add_padding(input_path, output_path, scale_factor=0.65):
    img = Image.open(input_path).convert("RGBA")
    width, height = img.size
    
    # Calculate new dimensions
    new_width = int(width * scale_factor)
    new_height = int(height * scale_factor)
    
    # Resize the image
    resized_img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
    
    # Create a new transparent image with the original dimensions
    new_img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    
    # Paste the resized image into the center
    x_offset = (width - new_width) // 2
    y_offset = (height - new_height) // 2
    new_img.paste(resized_img, (x_offset, y_offset))
    
    # Save the result
    new_img.save(output_path)
    print(f"Saved padded icon to {output_path}")

if __name__ == "__main__":
    add_padding("assets/icon/icon.png", "assets/icon/icon_foreground.png")
