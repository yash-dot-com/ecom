## implementing a ecommerce backend to learn 
- database indexing 
- searching
- query params
- filters, sorts & pagination
- database modelling. 

## Actors involved 
- user 
- admin 

## Actions involved
- user
    - signup / login 
    - browse products - filters, sorts, paginated list 
    - browse categories
    - search product 
    - add to cart / remove from cart / update quantity of items 
    - checkout - place order - dummy payment - get email for confirmation 
    - browse all previous order 

- admin
    - CRUD products
    - CRUD categories 
    - browse all orders
    - add / remove products to category 

## phase 2 
- full text postgres search 
- indexing and explain analyze 
- rate limit 
- logging 
- dockerize
- deploy 
- setup openAPI & swagger
- caching searches 
- set up monitoring

## frontend 
- sign up / login JWT based
- categories page 
- category products page 
- cart view 
- checkout 
- admin panel -> see products list per category -> CRUD products within category -> CRUD category -> see all orders sorted by date, amount, incr/ decr & filtered by categories, location, 

## database design 
- users
- products
- categories
- product_categories
- carts
- cart_items
- orders
- order_items

Order
├── id
├── userId
├── totalAmount
└── status

OrderItem
├── orderId
├── productId
├── quantity
└── priceAtPurchase

Cart
├── id
└── userId

CartItem
├── cartId
├── productId
└── quantity

## API contracts 
- products api 
    - to create product 
    - to update product 
    - to delete product 
    - to read single product 
    - to read list of products - paginated, filtering, sorting 



