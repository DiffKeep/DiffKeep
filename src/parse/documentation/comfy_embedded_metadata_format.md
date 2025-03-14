# ComfyUI Embedded Metadata: Workflow Format

## Introduction

ComfyUI, like most image generators, embeds its generation data into the files it generates.
This allows one to drag a generated image into the ComfyUI window and get the exact same workflow that was used to generate the image.

For PNG's, this is accomplished using [Chunks](http://www.libpng.org/pub/png/spec/1.2/PNG-Chunks.html), specifically `iTXt` Chunks. This allows arbitrary text to be saved inside the PNG file and easily read by other programs.

ComfyUI adds two `iTXt` Chunks into files: `prompt` and `workflow`.

## `prompt`

The `prompt` chunk is a collection of inputs for a given node in the workflow.
It is in JSON format, an object containing string numbers whose values are objects that contain inputs, class types, and metadata about the node.

Here is a shortened and annotated snippet from a `prompt` chunk:

```json
{ // beginning of the "prompt" object
  "4": { // the numerical ID of the node, stored as a string
    "inputs": { // list of inputs for this node
      "ckpt_name": "voightKampff_v03.safetensors", // an input name and value, in this case a checkpoint
      "seed": [ // input name, value is array for input from another node instead of a widget
        "10", // node that gives us the input
        3 // the above node's output slot ID
      ] // Note: this is not a valid input for this node type, just added it here to demonstrate
    },
    "class_type": "CheckpointLoaderSimple", // class type of this node
    "_meta": { // metadata list
      "title": "Load Checkpoint" // the title of the node, stored as metadata
    }
  },
  "5": { // the numerical ID of the node, stored as a string
    "inputs": { // list of inputs for this node
      "width": 896, // an input name and value, in this case the width of the latent
      "height": 1280, // input names are always strings, input values can be integers, floats, booleans, and strings
      "batch_size": 1
    },
    "class_type": "EmptyLatentImage", // class type of this node
    "_meta": { // metadata list
      "title": "Empty Latent Image" // the title of the node, stored as metadata
    }
  }
}
```

## `workflow`

The `workflow` chunk details the full workflow for the image, in JSON format.
It includes all nodes in the workflow how they are connected, any groups, and some other metadata.

Here is an abbreviated and annotated snippet from a `workflow` chunk:

```json
{
  "last_node_id": 203, // last node number used, increments each time a node is added but is not decremented when a node is removed
  "last_link_id": 431, // last link index created
  "nodes": [ // array of all the workflow's nodes
    {
      "id": 55, // ID of the node
      "type": "IPAdapterModelLoader", // the type of node
      "pos": [ // the position of the node in the UI in pixels (at 100% zoom)
        -824, // X position
        500 // Y position
      ],
      "size": { // the size of the node in the UI
        "0": 315, // width (x) in pixels (at 100% zoom)
        "1": 58 // height (y)
      },
      "flags": {}, // flags for the nodes. unsure what these can be yet
      "order": 0, // the order the nodes are processed in
      "mode": 4, // the mode for this node. 0 = always, 1 = on event, 2 = on trigger, 3 = never, 4 = bypass 
      "outputs": [ // list of all the node's outputs
        {
          "name": "IPADAPTER", // the name of this output
          "type": "IPADAPTER", // the data type for this output
          "links": [ // the id of "links" array below for this output
            130 // there can be multiple id's listed, one for each node this output links to
          ],
          "shape": 3, // the shape of the output? not sure what this does, not all outputs seem to have it
          "slot_index": 0 // the slot index of this output, used in links
        }
      ],
      "properties": { // properties for this node
        "Node name for S&R": "IPAdapterModelLoader" // node name for S&R (search and replace, for the placeholders in image save names?)
      },
      "widgets_values": [ // the values of all the non-input widgets
        "ip-adapter-plus_sdxl_vit-h.safetensors"
      ]
    },
    {
      "id": 57,
      "type": "CLIPVisionLoader",
      "pos": [
        -823,
        609
      ],
      "size": {
        "0": 315,
        "1": 58
      },
      "flags": {},
      "order": 1,
      "mode": 4,
      "outputs": [
        {
          "name": "CLIP_VISION",
          "type": "CLIP_VISION",
          "links": [
            132
          ],
          "shape": 3,
          "slot_index": 0
        }
      ],
      "properties": {
        "Node name for S&R": "CLIPVisionLoader"
      },
      "widgets_values": [
        "clip_ipadapter_15.safetensors"
      ]
    }
  ],
  "links": [ // an array of links between nodes
    [
      14, // link index
      11, // source node ID
      1, // source node's output slot index
      6, // target node ID
      0, // target node's input slot index
      "CLIP" // data type of this link. affects color
    ],
    [
      50,
      7,
      0,
      28,
      0,
      "*" // can link to anything? unknown data type?
    ]
  ],
  "groups": [ // array of all the groups in the UI
    {
      "title": "Upscale", // title of this group
      "bounding": [ // bounding box of the group
        360, // upper left corner x
        1481, // upper left corner y
        2177, // width (x)
        823 // height (y)
      ],
      "color": "#3f789e", // color of the group
      "font_size": 24 // font size of the title
    },
    {
      "title": "Group",
      "bounding": [
        1202,
        72,
        905,
        80
      ],
      "color": "#3f789e",
      "font_size": 24
    }
  ],
  "config": {}, // not sure what values can appear here
  "extra": { // extra workflow info
    "workspace_info": { // this seems to be used by the "workspace" extension
      "id": "P_T2UEaHAhZgYF_H9s_LF"
    },
    "ds": { // unsure what this is
      "scale": 2.143588810000005,
      "offset": {
        "0": -238.78800543247056,
        "1": 46.29050191911472
      }
    }
  },
  "version": 0.4, // format version?
  "widget_idx_map": { // unknown
    "21": {
      "seed": 0
    },
    "78": {
      "seed": 0,
      "sampler_name": 4,
      "scheduler": 5
    }
  }
}
```

Note that unlike the `prompt` chunk, the nodes listed here are in an array rather than an object indexed by numbered string ID's.

Custom extensions to ComfyUI can add data into this workflow as well.
Ideally this would be under the "extra" section, but it seems not all extensions follow this convention.

A missing piece of information from the workflow is what node the image is a result of; a workflow may have multiple image save nodes at different stages, and it seems that it is impossible to determine solely from the workflow which one is responsible for creating the workflow source image.
