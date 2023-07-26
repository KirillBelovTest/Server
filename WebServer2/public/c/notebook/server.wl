Get["https://raw.githubusercontent.com/JerryI/wolfram-js-frontend/master/Kernel/Colors.wl"]
Get["https://raw.githubusercontent.com/JerryI/wolfram-js-frontend/master/Kernel/Utils.wl"]
Get["https://raw.githubusercontent.com/JerryI/wolfram-js-frontend/master/Kernel/Cells.wl"]

(* A polyfill for secondary kernel that makes a loop back to the master kernel evaluation, during the creation of FrontEndObject *)
BeginPackage["JerryI`WolframJSFrontend`Remote`"];
$ExtendDefinitions::using = ""
Begin["Private`"]
$ExtendDefinitions[uid_, defs_] := With[{id = Global`$AssociationSocket[Global`client]}, 
    Print["a query to extend sent for "<>id];
    Global`NExtendSingleDefinition[uid, defs][id]  
];
End[];
EndPackage[];


(* support for graphics object transformation to the frontend objects *)
Get["https://raw.githubusercontent.com/JerryI/wolfram-js-frontend/master/Kernel/WebObjects.wl"]
(* support for post-evaluation transformation, i.e. boxes transformation and etc *)
Get["https://raw.githubusercontent.com/JerryI/wolfram-js-frontend/master/Kernel/Evaluator.wl"]

(* load graphics packages and etc (usually it can be done automatically using plugins in the original WLJS Frontend) *)

Get["https://raw.githubusercontent.com/JerryI/wljs-editor/main/src/boxes.wl"]
Get["https://raw.githubusercontent.com/JerryI/wljs-graphics-d3/main/src/kernel.wl"]
Get["https://raw.githubusercontent.com/JerryI/wljs-plotly/main/src/kernel.wl"]

(* build a replacement table for graphics object defined in the previous three lines *)
LoadWebObjects[];

(* loop back to evaluate everyhting at the master kernel *)
LocalKernel[ev_, cbk_, OptionsPattern[]] := (
    (* execute on the master kernel *)
    ev[cbk];
);

(* notebooks storage *)
JerryI`WolframJSFrontend`Notebook`Notebooks = <||>

(* processors, i.e. Wolfram Processor, HTML and etc *)
Processors = {{}, {}, {}}

Unprotect[NotebookOpen]
ClearAll[NotebookOpen]

(* match between socket object and associated notebook id *)
$AssociationSocket = <||>

NotebookOpen[id_String] := With[{cli = Global`client},
    console["log", "generating the three of `` for ``", id, Global`client];

    If[!KeyExistsQ[JerryI`WolframJSFrontend`Notebook`Notebooks, id], NotebookCreate["id"->id, "name"->id, "path"->Null]];
    $AssociationSocket[Global`client] = id;

    (* generate cells lively *)
    Block[{JerryI`WolframJSFrontend`fireEvent = NotebookEventFire[Global`client]},
        CellListTree[id];
    ];
];

Unprotect[NotebookEvaluate]
ClearAll[NotebookEvaluate]
NotebookEvaluate[]

NotebookEvaluate[cellid_] := (
    Block[{JerryI`WolframJSFrontend`fireEvent = NotebookEventFire[Global`client]},
        CellObjEvaluate[CellObj[cellid], Processors];
    ];
);

(* helper funtions to add language processors *)
JerryI`WolframJSFrontend`Notebook`NotebookAddEvaluator[type_] := Processors[[2]] = Join[{type}, Processors[[2]]];
JerryI`WolframJSFrontend`Notebook`NotebookAddEvaluator[type_, "HighestPriority"] := Processors[[1]] = Join[{type}, Processors[[1]]];
JerryI`WolframJSFrontend`Notebook`NotebookAddEvaluator[type_, "LowestPriority"] := Processors[[3]] = Join[{type}, Processors[[3]]];

(* get the default wolfram language processor *)
Get["https://raw.githubusercontent.com/JerryI/wljs-editor/main/src/processor.wl"]


Unprotect[NotebookCreate]
ClearAll[NotebookCreate]

Options[NotebookCreate] = {
    "name" -> "Untitled",
    "signature" -> "wsf-notebook",
    "id" :> CreateUUID[],
    "kernel" -> LocalKernel,
    "objects" -> <||>,
    "cell" -> Null,
    "data" -> "",
    "path" -> Null
};

NotebookCreate[OptionsPattern[]] := (
    With[{id = OptionValue["id"]},

        JerryI`WolframJSFrontend`Notebook`Notebooks[id] = <|
            "name" -> OptionValue["name"],
            "id"   -> id,
            "kernel" -> OptionValue["kernel"],
            "objects" -> OptionValue["objects"] ,
            "path" -> OptionValue["path"],
            "cell" :> Exit[] (* to catch old ones *)       
        |>;

        CellList[id] = { CellObj["sign"->id, "type"->"input", "data"->OptionValue["data"]] };
        id
    ]
);

NotebookOperate[cellid_, op_] := (
    Block[{JerryI`WolframJSFrontend`fireEvent = NotebookEventFire[Global`client]},
        op[CellObj[cellid]];
    ];
);

NotebookOperate[cellid_, op_, arg_] := (
    Block[{JerryI`WolframJSFrontend`fireEvent = NotebookEventFire[Global`client]},
        op[CellObj[cellid], arg];
    ];
);

(* extend the frontend object storage *)
NExtendSingleDefinition[uid_, defs_][notebook_] := Module[{updated = False},
    Print["Direct definition extension"];

    updated = KeyExistsQ[JerryI`WolframJSFrontend`Notebook`Notebooks[notebook]["objects"], uid];

    JerryI`WolframJSFrontend`Notebook`Notebooks[notebook]["objects"][uid] = defs; 

    If[updated,
        Print["Will be updated! NExtend"];
        WebSocketSend[Global`client, Global`UpdateFrontEndExecutable[uid, defs["json"] ] // $DefaultSerializer];  
    ];  
]

(* get the frontend object from storage *)
NotebookGetObject[uid_] := Module[{obj}, With[{channel = $AssociationSocket[Global`client]},
    If[!KeyExistsQ[JerryI`WolframJSFrontend`Notebook`Notebooks[channel]["objects"], uid],
        Print["we did not find an object "<>uid<>" at the master kernel. failed"];
        Print["notebook: "<>channel];
        Return[$Failed];
    ];
    Print[StringTemplate["getting object `` with data inside \n `` \n"][uid, JerryI`WolframJSFrontend`Notebook`Notebooks[channel]["objects"][uid]//Compress]];

    JerryI`WolframJSFrontend`Notebook`Notebooks[channel]["objects"][uid]["date"] = Now;
    JerryI`WolframJSFrontend`Notebook`Notebooks[channel]["objects"][uid]["json"]
]];


(* events used to oeprate with cells. prerenders it on the server *)

NotebookEventFire[addr_]["NewCell"][cell_] := (
    (*looks ugly actually. we do not need so much info*)
    console["log", "fire event `` for ``", cell, addr];
    With[
        {
            obj = <|
                        "id"->cell[[1]], 
                        "sign"->cell["sign"],
                        "type"->cell["type"],
                        "data"->If[cell["data"]//NullQ, "", ExportString[cell["data"], "String", CharacterEncoding -> "UTF8"] ],
                        "props"->cell["props"],
                        "display"->cell["display"],
                        "state"->If[StringQ[ cell["state"] ], cell["state"], "idle"]
                    |>,

            (* prerender *)
            template = LoadPage[FileNameJoin[{"c", "notebook", cell["type"]<>".wsp"}], {Global`id = cell[[1]]}, "Base"->FileNameJoin[{Directory[], "public"}]]
        },

        WebSocketSend[addr, Global`FrontEndCreateCell[template, obj ] // $DefaultSerializer];
    ];
);

NotebookEventFire[addr_]["RemovedCell"][cell_] := (
    (*actually frirstly you need to check!*)
  
    With[
        {
            obj = <|
                        "id"->cell[[1]], 
                        "sign"->cell["sign"],
                        "type"->cell["type"]
                    |>
        },

        WebSocketSend[addr, Global`FrontEndRemoveCell[obj] // $DefaultSerializer];
    ];
);

NotebookEventFire[addr_]["UpdateState"][cell_] := (
    With[
        {
            obj = <|
                        "id"->cell[[1]], 
                        "sign"->cell["sign"],
                        "type"->cell["type"],
                        "state"->cell["state"]
                    |>
        },

        WebSocketSend[addr, Global`FrontEndUpdateCellState[obj ] // $DefaultSerializer];
    ];
);

NotebookEventFire[addr_]["AddCellAfter"][next_, parent_] := (
    Print["Add cell after"];
    (*looks ugly actually. we do not need so much info*)
    console["log", "fire event `` for ``", next, addr];
    With[
        {
            obj = <|
                        "id"->next[[1]], 
                        "sign"->next["sign"],
                        "type"->next["type"],
                        "data"->If[next["data"]//NullQ, "", ExportString[next["data"], "String", CharacterEncoding -> "UTF8"] ],
                        "props"->next["props"],
                        "display"->next["display"],
                        "state"->If[StringQ[ next["state"] ], next["state"], "idle"],
                        "after"-> <|
                            "id"->parent[[1]], 
                            "sign"->parent["sign"],
                            "type"->parent["type"]                           
                        |>
                    |>,
            
            template = LoadPage[FileNameJoin[{"c", "notebook", next["type"]<>".wsp"}], {Global`id = next[[1]]}, "Base"->FileNameJoin[{Directory[], "public"}]]
        },


        WebSocketSend[addr, Global`FrontEndCreateCell[template, obj ] // $DefaultSerializer];
    ];
);

(* when the output cell changes to the input one *)
NotebookEventFire[addr_]["CellMorphInput"][cell_] := (
    (*looks ugly actually. we do not need so much info*)
    console["log", "fire event `` for ``", cell, addr];
    With[
        {
            obj = <|
                        "id"->cell[[1]], 
                        "sign"->cell["sign"],
                        "type"->cell["type"]
                    |>,
            
            template = LoadPage[FileNameJoin[{"c", "notebook", "input.wsp"}], {Global`id = cell[[1]]}, "Base"->FileNameJoin[{Directory[], "public"}]]
        },

        WebSocketSend[addr, Global`FrontEndCellMorphInput[template, obj ] // $DefaultSerializer];
    ];
);

NotebookEventFire[addr_]["CellMorph"][cell_] := (Null);


