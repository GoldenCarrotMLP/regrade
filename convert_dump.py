import re

# Path to your input and output files
input_path = "/home/anderson/supabase-project/jobsbackup.sql"
output_path = "/home/anderson/supabase-project/jobsbackup_cleaned.sql"

# Define the target table and columns
table_name = "repair_jobs_new"
columns = [
    "id", "created_at", "status", "repair_level", "completed_date", "technician",
    "was_split", "pause", "order_id", "jobs_temp", "job_id"
]

def convert_line_to_values(line):
    # Skip empty lines or metadata
    if line.startswith("pg_dump") or line.strip() == "" or line.strip() == "\\.":
        return None

    # Split by tab
    fields = line.strip().split("\t")

    # Replace \N with NULL and wrap strings in single quotes
    converted = []
    for field in fields:
        if field == r"\N":
            converted.append("NULL")
        elif re.match(r"^\d+$", field):  # Integer
            converted.append(field)
        else:
            converted.append(f"'{field}'")
    return f"({', '.join(converted)})"

def main():
    with open(input_path, "r") as infile, open(output_path, "w") as outfile:
        outfile.write(f"INSERT INTO public.{table_name} ({', '.join(columns)}) VALUES\n")
        values = []

        for line in infile:
            converted = convert_line_to_values(line)
            if converted:
                values.append(converted)

        outfile.write(",\n".join(values) + ";\n")

if __name__ == "__main__":
    main()
