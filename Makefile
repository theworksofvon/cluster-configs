.PHONY: help
help:
	@echo "Available commands:"
	@echo "  make validate       - Validate all manifests in clusters/"
	@echo "  make validate-dir   - Validate specific directory (use DIR=path)"
	@echo "  make clean          - Clean up temporary files"
	@echo "  make help           - Show this help"

.PHONY: validate
validate:
	@./clusters/validate.sh

.PHONY: validate-dir
validate-dir:
	@if [ -z "$(DIR)" ]; then \
		echo "Error: Please specify DIR=path"; \
		exit 1; \
	fi
	@./clusters/validate.sh $(DIR)

.PHONY: clean
clean:
	@rm -rf .validation-output .local/bin 