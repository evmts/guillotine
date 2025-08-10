#!/bin/bash
# Format all Zig files in the project

echo "Formatting all Zig files..."
zig fmt .

if [ $? -eq 0 ]; then
    echo "✅ All files formatted successfully!"
else
    echo "❌ Formatting failed. Please check the errors above."
    exit 1
fi

# Optionally check if any files were changed
if git diff --quiet; then
    echo "No files were changed - all files were already properly formatted."
else
    echo "Files were formatted. Run 'git diff' to see the changes."
fi