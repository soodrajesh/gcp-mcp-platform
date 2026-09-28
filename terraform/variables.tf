variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "admin_email" {
  description = "The human operator: registered caller with every scope."
  type        = string
}

variable "alert_email" {
  type = string
}

variable "suffix" {
  description = "Per-deployment suffix for the Firestore database id (a deleted database's id cannot be reused immediately)."
  type        = string
}

variable "image" {
  description = "Digest-pinned image for both MCP servers. Empty = phase 1 (infrastructure only)."
  type        = string
  default     = ""
}

variable "rate_limit_per_min" {
  type    = number
  default = 60
}
