import sys
import re

def process_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Revert 8090:8080 to 8090:80
    content = content.replace('"8090:8080"', '"8090:80"')
    
    def replacer(match):
        indent = match.group(1)
        image_line = match.group(2)
        if 'user: "root"' in content[match.end():match.end()+100]:
            return match.group(0)
        return f"{indent}{image_line}\n{indent}user: \"root\"\n{indent}command: [\"-port\", \"80\"]"
    
    new_content = re.sub(r'^([ \t]*)(image:[ \t]*mccutchen/go-httpbin.*)$', replacer, content, flags=re.MULTILINE)
    
    with open(filepath, 'w') as f:
        f.write(new_content)

if __name__ == "__main__":
    for filepath in sys.argv[1:]:
        process_file(filepath)
