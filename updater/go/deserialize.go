package main

import (
	"database/sql"
	"io"

	"github.com/rs/zerolog/log"
	"github.com/ugorji/go/codec"
)

var cborHandle = codec.CborHandle{}

type NullString struct {
	sql.NullString
}

func (ns *NullString) CodecEncodeSelf(enc *codec.Encoder) {
	if ns.Valid {
		enc.MustEncode(ns.String)
	} else {
		enc.MustEncode(nil)
	}
}

func (ns *NullString) CodecDecodeSelf(dec *codec.Decoder) {
	var v interface{}
	dec.MustDecode(&v)
	switch v.(type) {
	case string:
		ns.Valid = true
		ns.String = v.(string)
	case nil:
	default:
		log.Warn().Interface("value", v).Msg("invalid NullString value")
	}
}

type ConfigData struct {
	Modules []string      `json:"modules"`
	Nodes   []ConfigParam `json:"nodes"`
}

type ConfigParam struct {
	ID          int
	ContentType string
	Value       NullString
	Version     int
	Path        string
	Name        string
	MTime       string
}

func deserializeConfigData(r io.Reader) (*ConfigData, error) {
	dec := codec.NewDecoder(r, &cborHandle)
	var data ConfigData
	err := dec.Decode(&data)
	return &data, err
}
