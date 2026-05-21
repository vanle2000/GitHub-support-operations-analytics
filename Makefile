
.PHONY: install data test lint clean

install:
	pip install -r requirements.txt
	python -m nltk.downloader vader_lexicon

data:
	python scripts/generate_synthetic_data.py

test:
	pytest tests/ -v --cov=src --cov-report=term-missing

lint:
	flake8 src/ scripts/ tests/ --max-line-length=100

clean:
	find . -type f -name "*.pyc" -delete
	rm -f data/raw/helpdesk_tickets.csv
