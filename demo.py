import boto3
import csv

def export_tags_to_csv(filename="resource_tags.csv"):
    # Initialize the Resource Groups Tagging API client
    client = boto3.client('resourcegroupstaggingapi')
    
    # Prepare the CSV file
    with open(filename, mode='w', newline='', encoding='utf-8') as file:
        writer = csv.writer(file)
        # Write the header
        writer.writerow(["ResourceARN", "TagKey", "TagValue"])
        
        # Use a paginator to handle large numbers of resources
        paginator = client.get_paginator('get_resources')
        
        print(f"Fetching tags... this may take a moment.")
        
        for page in paginator.paginate():
            for resource in page['ResourceTagMappingList']:
                arn = resource['ResourceARN']
                tags = resource['Tags']
                
                # Write each tag for the resource as a separate row
                if tags:
                    for tag in tags:
                        writer.writerow([arn, tag['Key'], tag['Value']])
                else:
                    # Capture resources that have no tags
                    writer.writerow([arn, "N/A", "N/A"])
                    
    print(f"Successfully exported tags to {filename}")

if __name__ == "__main__":
    export_tags_to_csv()
