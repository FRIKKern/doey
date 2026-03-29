package hetzner

// latencyHint returns a human-friendly latency hint for a Hetzner location
func latencyHint(locationName string) string {
	hints := map[string]string{
		"fsn1": "~5ms from central EU",
		"nbg1": "~5ms from central EU",
		"hel1": "~15ms from EU, ~30ms Nordics",
		"ash":  "~15ms from US East",
		"hil":  "~20ms from US West",
		"sin":  "~5ms from SEA",
	}
	if h, ok := hints[locationName]; ok {
		return h
	}
	return ""
}

// priceForType returns approximate monthly price for a Hetzner server type
func priceForType(typeName string) string {
	prices := map[string]string{
		"cx22":  "€3.99/mo",
		"cx32":  "€6.49/mo",
		"cx42":  "€15.49/mo",
		"cx52":  "€29.99/mo",
		"cpx11": "€3.99/mo",
		"cpx21": "€5.49/mo",
		"cpx31": "€9.49/mo",
		"cpx41": "€16.49/mo",
		"cpx51": "€29.49/mo",
		"ccx13": "€12.99/mo",
		"ccx23": "€22.99/mo",
		"ccx33": "€41.99/mo",
		"ccx43": "€76.99/mo",
		"ccx53": "€146.99/mo",
		"ccx63": "€283.99/mo",
	}
	if p, ok := prices[typeName]; ok {
		return p
	}
	return "see hetzner.com"
}

// RecommendedTypes returns the server types we suggest for Doey
func RecommendedTypes() []string {
	return []string{"cx22", "cx32", "cx42", "cpx21", "cpx31", "ccx13", "ccx23"}
}
