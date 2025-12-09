package types

import "encoding/json"

type ConfigurationRequest struct {
	Components []ComponentConfig `json:"components"`
}

type ComponentConfig struct {
	Type               string             `json:"type"`
	Name               string             `json:"name"`
	Hash               string             `json:"hash"`
	Tags               []string           `json:"tags"`
	Handler            string             `json:"handler,omitempty"`
	Content            string             `json:"content,omitempty"`
	ContentURL         string             `json:"content_url,omitempty"`
	ContentURLEncoding string             `json:"content_url_encoding,omitempty"`
	NomadJob           string             `json:"nomad_job,omitempty"`
	NomadJobData       *json.RawMessage   `json:"nomad_job_data,omitempty"`
	Managed            bool               `json:"managed,omitempty"`
	HealthCheck        *HealthCheckConfig `json:"health_check,omitempty"`
	Env                map[string]string  `json:"env,omitempty"`
	Args               []string           `json:"args,omitempty"`
}

type HealthCheckConfig struct {
	Type            string `json:"type"`
	Endpoint        string `json:"endpoint,omitempty"`
	IntervalSeconds int32  `json:"interval_seconds"`
	TimeoutSeconds  int32  `json:"timeout_seconds"`
	Retries         int32  `json:"retries"`
}
