import xml.etree.ElementTree as ET
import urllib.request
import urllib.error
import os
import ssl
import socket

FILES_TO_PROCESS = [

    '/Users/rooshi/Documents/programming/flutter/notube_mobile/feeds.opml'
]

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36'
}

# Create unverified context to avoid SSL errors on some systems
ssl_context = ssl._create_unverified_context()

def check_url(url):
    if not url:
        return False
    # Handle http vs https if needed? urlopen handles both.
    if not url.startswith('http'):
        url = 'http://' + url
        
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        # Reduced timeout to 3 seconds as requested
        with urllib.request.urlopen(req, timeout=3, context=ssl_context) as response:
            if response.getcode() == 200:
                return True
            else:
                print(f"[-] Bad status {response.getcode()}: {url}")
                return False
    except urllib.error.HTTPError as e:
        print(f"[-] HTTP Error {e.code}: {url}")
        return False
    except urllib.error.URLError as e:
        # Some URL errors like "certificate verify failed" might still happen if context isn't used right, 
        # but we are using it. Other errors like DNS failure will be caught here.
        print(f"[-] URL Error {e.reason}: {url}")
        return False
    except socket.timeout:
        print(f"[-] Timeout: {url}")
        return False
    except Exception as e:
        print(f"[-] Error {e}: {url}")
        return False

def process_element(element, parent=None):
    # Return a list of children to remove
    to_remove = []
    
    # Iterate over copy of children to safely modify/mark
    for child in list(element):
        # Check if this child has children (Folder)
        if len(list(child)) > 0:
            process_element(child, element)
        
        # Check if this child is a feed
        xmlUrl = child.get('xmlUrl')
        htmlUrl = child.get('htmlUrl')
        url_to_check = xmlUrl if xmlUrl else htmlUrl
        
        if url_to_check:
            print(f"[*] Checking: {child.get('text', 'Unknown')} ({url_to_check})")
            if not check_url(url_to_check):
                to_remove.append(child)
    
    for child in to_remove:
        print(f"[x] Removing: {child.get('text', 'Unknown')}")
        element.remove(child)

def process_file(filepath):
    print(f"Processing {filepath}...")
    try:
        tree = ET.parse(filepath)
        root = tree.getroot()
        
        # Body contains the outlines
        body = root.find('body')
        if body is not None:
            process_element(body)
        
        # Save back
        tree.write(filepath, encoding='UTF-8', xml_declaration=True)
        print(f"Finished {filepath}")
    except Exception as e:
        print(f"Failed to process {filepath}: {e}")

if __name__ == "__main__":
    for f in FILES_TO_PROCESS:
        if os.path.exists(f):
            process_file(f)
        else:
            print(f"File not found: {f}")
