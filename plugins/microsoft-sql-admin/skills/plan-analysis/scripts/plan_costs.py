# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.
"""Read Showplan XML and compute per-statement own-cost rankings; no SQL execution."""
import argparse
import json
import sys
import xml.etree.ElementTree as ET
from decimal import Decimal, InvalidOperation
from pathlib import Path

NS={'s':'http://schemas.microsoft.com/sqlserver/2004/07/showplan'}


def analyze(xml,top=5):
    if '<!DOCTYPE' in xml.upper() or '<!ENTITY' in xml.upper():
        raise ValueError('DTD/entity declarations are outside the Showplan input contract')
    root=ET.fromstring(xml)
    statements=root.findall('.//s:StmtSimple',NS)
    if not statements: raise ValueError('No Showplan StmtSimple elements found')
    output=[]
    for statement in statements:
        total=Decimal(statement.attrib['StatementSubTreeCost'])
        if not total.is_finite() or total<=0: raise ValueError('Statement cost must be positive and finite')
        nodes=statement.findall('s:QueryPlan//s:RelOp',NS)
        if not nodes: raise ValueError('Statement contains no operators')
        operators=[];seen=set()
        for node in nodes:
            node_id=int(node.attrib['NodeId'])
            if node_id in seen: raise ValueError('Duplicate NodeId within a statement')
            seen.add(node_id)
            subtree=Decimal(node.attrib['EstimatedTotalSubtreeCost'])
            children=[Decimal(child.attrib['EstimatedTotalSubtreeCost']) for child in node.findall('s:*/s:RelOp',NS)]
            if any(not value.is_finite() or value<0 for value in [subtree,*children]):
                raise ValueError('Operator costs must be nonnegative and finite')
            raw=subtree-sum(children,Decimal(0))
            own=max(Decimal(0),raw)
            operators.append({'node_id':node_id,'subtree_cost':str(subtree),'raw_own_cost':str(raw),
                              'own_cost':str(own),'percent':str(own*100/total)})
        operators.sort(key=lambda node:(-Decimal(node['own_cost']),node['node_id']))
        own_sum=sum((Decimal(node['own_cost']) for node in operators),Decimal(0))
        selected=operators[:top]
        output.append({'statement_id':statement.attrib.get('StatementId'),'statement_cost':str(total),
            'operator_count':len(operators),'operators':operators,'top':selected,
            'sum_own_costs':str(own_sum),'own_sum_minus_statement_cost':str(own_sum-total),
            'top_percent_rounded_2dp':str((sum((Decimal(node['own_cost']) for node in selected),Decimal(0))*100/total).quantize(Decimal('0.01'))),
            'negative_raw_own_cost_nodes':[node['node_id'] for node in operators if Decimal(node['raw_own_cost'])<0]})
    return output


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plan',type=Path)
    parser.add_argument('--top',type=int,default=5)
    args=parser.parse_args()
    if args.top<1: parser.error('--top must be positive')
    try:
        result=analyze(args.plan.read_text(encoding='utf-8-sig'),args.top)
    except (OSError,ValueError,KeyError,ET.ParseError,InvalidOperation) as error:
        print(json.dumps({'status':'error','error':str(error)}),file=sys.stderr)
        return 2
    print(json.dumps({'status':'ok','statements':result},indent=2))
    return 0


if __name__=='__main__': raise SystemExit(main())
