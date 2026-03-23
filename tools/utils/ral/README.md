# ral (Rename and Lowercase)

RAL is a powerful utility written in C to mass rename files by replacing spaces with dots and converting all characters to lowercase. It's designed for efficiency and speed, handling large volumes of files quickly without the overhead of a scripting language.

## Motivation
Provide a fast, reliable way to normalize file names across various directories, especially useful in environments where file naming consistency is crucial.

## Features
- Replace spaces with dots in filenames (or custom chars).
- Convert filenames to lowercase.
- Handle directories recursively.
- Automatically handle filename conflicts by removing existing files with the target name.

## Compile

```bash
clang ral.c -o ral
chmod +x ral
sudo mv ral /usr/local/bin
```

## Usage
```bash
ral .                 rename all files in the current directory
ral /ftp/incoming/    rename files in the /ftp/incoming firectory
ral -r .              rename all files recursivally from the current directoy
ral -r -d _ .         same +replae spaces with underscores _
```
or 
crontab -e 
```*/5 * * * * /usr/local/bin/ral /tv/ .```
